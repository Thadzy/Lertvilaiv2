/**
 * Fleet Socket Hook
 * =================
 * Polls the Fleet Gateway GraphQL API (port 8080, proxied at /api/fleet)
 * for live robot state. Replaces the previous MQTT-based implementation
 * which targeted an external broker that our Redis-based stack never published to.
 *
 * Data flow:
 *   robot_simulator → rosbridge → robot_bridge → Redis
 *   → fleet_gateway (GraphQL /api/fleet/graphql) ← this hook polls here
 */

import { useEffect, useState, useCallback, useRef, useMemo } from 'react';
import { VEHICLE_ROBOT_MAP } from '../utils/fleetGateway';

// ============================================
// CONFIGURATION
// ============================================

const FLEET_GW_URL = '/api/fleet/graphql';

/** How often to poll fleet_gateway for robot state (ms) */
const POLL_INTERVAL_MS = 200;

// ============================================
// TYPE DEFINITIONS
// ============================================

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'reconnecting';

export interface RobotStatusMessage {
    id: string | number;
    status: 'idle' | 'busy' | 'offline' | 'error';
    battery: number;
    x: number;
    y: number;
    angle?: number;
    current_task_id?: number | null;
}

export interface FleetLogMessage {
    msg: string;
    timestamp: number;
}

export interface RobotCommand {
    command: 'GOTO' | 'PAUSE' | 'RESUME' | 'ESTOP';
    target_x?: number;
    target_y?: number;
    robotName?: string;
    timestamp: number;
}

export interface UseFleetSocketReturn {
    connectionStatus: ConnectionStatus;
    isConnected: boolean;
    robotStates: Readonly<Record<string, RobotStatusMessage>>;
    logs: readonly string[];
    reconnectAttempts: number;
    publishCommand: (robotId: number | string, command: RobotCommand['command'], payload?: Partial<RobotCommand>) => void;
    forceReconnect: () => void;
    addLog: (msg: string) => void;
}

// ============================================
// GraphQL query — fetch all robot states
// ============================================

const ROBOTS_QUERY = `
  query {
    robots {
      name
      connectionStatus
      mobileBaseState {
        pose { x y }
      }
    }
  }
`;

interface GqlRobot {
    name: string;
    connectionStatus: 'ONLINE' | 'OFFLINE';
    mobileBaseState?: {
        pose?: { x: number; y: number } | null;
    } | null;
}

// ============================================
// HOOK IMPLEMENTATION
// ============================================

export const useFleetSocket = (): UseFleetSocketReturn => {
    const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>('disconnected');
    const [robotStates, setRobotStates] = useState<Record<string, RobotStatusMessage>>({});
    const [logs, setLogs] = useState<string[]>([]);
    const [reconnectAttempts, setReconnectAttempts] = useState(0);

    const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
    const isMountedRef = useRef(true);

    const addLog = useCallback((msg: string) => {
        setLogs(prev => [msg, ...prev].slice(0, 50));
    }, []);

    const poll = useCallback(async () => {
        try {
            const res = await fetch(FLEET_GW_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ query: ROBOTS_QUERY }),
                signal: AbortSignal.timeout(3000),
            });

            if (!res.ok) throw new Error(`HTTP ${res.status}`);

            const body = await res.json();
            if (body.errors?.length) throw new Error(body.errors[0].message);

            if (!isMountedRef.current) return;

            const gqlRobots: GqlRobot[] = body.data?.robots ?? [];
            const next: Record<string, RobotStatusMessage> = {};

            gqlRobots.forEach((r) => {
                const pose = r.mobileBaseState?.pose;

                let status: RobotStatusMessage['status'] = 'offline';
                if (r.connectionStatus === 'ONLINE') {
                    status = 'idle';
                }

                const entry: RobotStatusMessage = {
                    id: r.name,
                    status,
                    battery: 100,
                    x: pose?.x ?? 0,
                    y: pose?.y ?? 0,
                    angle: 0,
                };

                next[r.name] = entry;
            });

            setRobotStates(next);

            if (connectionStatus !== 'connected') {
                setConnectionStatus('connected');
                setReconnectAttempts(0);
            }
        } catch (err) {
            if (!isMountedRef.current) return;
            console.error('[FleetSocket] Poll Error:', err);
            if (connectionStatus === 'connected') {
                console.warn('[FleetSocket] Poll failed:', err);
                setConnectionStatus('reconnecting');
                setReconnectAttempts(prev => prev + 1);
            } else {
                setConnectionStatus('disconnected');
            }
        }
    }, [connectionStatus]);

    // Start / restart polling
    const startPolling = useCallback(() => {
        if (intervalRef.current) clearInterval(intervalRef.current);
        setConnectionStatus('connecting');
        poll(); // immediate first call
        intervalRef.current = setInterval(poll, POLL_INTERVAL_MS);
    }, [poll]);

    const forceReconnect = useCallback(() => {
        setReconnectAttempts(0);
        startPolling();
    }, [startPolling]);

    // publishCommand: send via fleet_gateway GraphQL mutation
    const publishCommand = useCallback(async (
        robotId: number | string,
        command: RobotCommand['command'],
        payload?: Partial<RobotCommand>,
    ) => {
        const inferredRobotName =
            payload?.robotName
            ?? (typeof robotId === 'string' ? robotId : VEHICLE_ROBOT_MAP[Math.max(Number(robotId) - 1, 0)])
            ?? String(robotId);

        console.log(`[FleetSocket] Sending Command ${command} → Robot ${inferredRobotName}`);
        addLog(`[System] Executing ${command} on ${inferredRobotName}...`);

        try {
            const query = `
                mutation SendCommand($robotName: String!, $command: String!) {
                    sendRobotCommand(robotName: $robotName, command: $command) {
                        success
                        message
                    }
                }
            `;

            const res = await fetch(FLEET_GW_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    query,
                    variables: { robotName: inferredRobotName, command }
                }),
                signal: AbortSignal.timeout(5000),
            });

            if (!res.ok) throw new Error(`HTTP Error ${res.status}`);

            const body = await res.json();
            if (body.errors?.length) throw new Error(body.errors[0].message);

            addLog(`[System] ${command} sent successfully to ${inferredRobotName}`);

        } catch (err) {
            console.error(`[FleetSocket] Failed to send ${command}:`, err);
            addLog(`[Error] Failed to send ${command} to ${inferredRobotName}`);
        }
    }, [addLog]);

    useEffect(() => {
        isMountedRef.current = true;
        startPolling();

        return () => {
            isMountedRef.current = false;
            if (intervalRef.current) clearInterval(intervalRef.current);
        };
    }, []); // eslint-disable-line react-hooks/exhaustive-deps

    const isConnected = connectionStatus === 'connected';

    return useMemo(() => ({
        connectionStatus,
        isConnected,
        robotStates,
        logs,
        reconnectAttempts,
        publishCommand,
        forceReconnect,
        addLog,
    }), [connectionStatus, isConnected, robotStates, logs, reconnectAttempts, publishCommand, forceReconnect, addLog]);
};

export default useFleetSocket;
