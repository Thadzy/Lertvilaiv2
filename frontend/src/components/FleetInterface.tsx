import React, { useState, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { LayoutGrid, Cpu, Activity, ArrowLeft } from 'lucide-react';
import GraphEditor from './GraphEditor';
import Optimization from './Optimization';
import FleetController from './FleetController';
import ThemeToggle from './ThemeToggle';
import { beginNewDispatchBatch, dispatchVehicleRoute, VEHICLE_ROBOT_MAP } from '../utils/fleetGateway';
import { type DBNode } from '../types/database';

const FleetInterface: React.FC = () => {
  const { graphId } = useParams<{ graphId: string }>(); // Get ID from URL
  const navigate = useNavigate();

  const [activeTab, setActiveTab] = useState<'graph' | 'opt' | 'fleet'>('graph');

  // Shared state: VRP simulation routes (number[][] — one path per vehicle)
  // Used purely for drawing the visual green paths on the Fleet tab.
  const [simulationRoutes, setSimulationRoutes] = useState<number[][] | null>(null);

  /**
   * Called by Optimization when user clicks "Dispatch to Fleet".
   * Updated to utilize the closed-loop batch execution architecture.
   */
  const handleDispatch = useCallback((
    expandedRoutes: number[][],
    vrpWaypoints: number[][], // Raw VRP node indices (e.g., [1, 62, 71, 1])
    nodes: DBNode[], // Kept for interface compatibility with the Optimization component
  ) => {
    // 1. Set the expanded routes for the UI to draw the simulation lines
    setSimulationRoutes(expandedRoutes);
    setActiveTab('fleet');

    // 2. Abort any previous dispatch sequences
    beginNewDispatchBatch();

    // 3. Fire-and-forget: send the raw VRP array to the Fleet Gateway
    // The backend route_oracle will handle the A* expansion and execution.
    vrpWaypoints.forEach((vrpPathArray, vehicleIndex) => {
      // Ensure the vehicle index is mapped to a physical robot
      if (!(vehicleIndex in VEHICLE_ROBOT_MAP)) return;

      if (!graphId) {
        console.error('[FleetInterface] Missing graphId for dispatch.');
        return;
      }

      const currentGraphId = parseInt(graphId, 10);

      // Dispatch the batch command via the updated fleetGateway utility
      dispatchVehicleRoute(vehicleIndex, currentGraphId, vrpPathArray)
        .then(result => {
          console.log(
            `[FleetInterface] Vehicle ${vehicleIndex + 1} batch dispatch complete:`,
            result
          );
          if (result.log) {
            result.log.forEach(entry => console.log(`  ${entry}`));
          }
        })
        .catch(err => {
          console.error(`[FleetInterface] Vehicle ${vehicleIndex + 1} batch dispatch failed:`, err);
        });
    });
  }, [graphId]);

  // Basic validation
  if (!graphId) return <div>Error: No Warehouse ID provided.</div>;

  const currentGraphId = parseInt(graphId, 10);

  return (
    <div className="flex flex-col h-screen bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors">

      {/* HEADER */}
      <div className="h-14 bg-white dark:bg-[#121214] border-b border-gray-200 dark:border-white/5 px-4 flex justify-between items-center shadow-sm z-20">

        <div className="flex items-center gap-4">

          {/* Back Button */}
          <button
            onClick={() => navigate('/')}
            className="p-2 text-slate-500 hover:bg-slate-100 hover:text-slate-800 rounded-full transition-colors"
            title="Back to Dashboard"
          >
            <ArrowLeft size={20} />
          </button>

          <div className="h-6 w-px bg-gray-200 dark:bg-white/10"></div>

          <h1 className="text-lg font-bold bg-clip-text text-transparent bg-gradient-to-r from-blue-600 to-indigo-600">
            Warehouse Editor <span className="text-slate-400 text-xs font-mono ml-2">#{currentGraphId}</span>
          </h1>
        </div>

        <div className="flex items-center gap-4">
          <div className="flex bg-gray-100 dark:bg-white/5 p-1 rounded-lg border border-gray-200 dark:border-white/10">
            <button
              onClick={() => setActiveTab('graph')}
              className={`flex items-center gap-2 px-4 py-1.5 rounded-md text-xs font-bold transition-all ${activeTab === 'graph' ? 'bg-white dark:bg-white/10 text-blue-600 dark:text-blue-400 shadow-sm' : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-white'}`}
            >
              <LayoutGrid size={14} /> GRAPH
            </button>
            <button
              onClick={() => setActiveTab('opt')}
              className={`flex items-center gap-2 px-4 py-1.5 rounded-md text-xs font-bold transition-all ${activeTab === 'opt' ? 'bg-white dark:bg-white/10 text-purple-600 dark:text-purple-400 shadow-sm' : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-white'}`}
            >
              <Cpu size={14} /> OPTIMIZATION
            </button>
            <button
              onClick={() => setActiveTab('fleet')}
              className={`flex items-center gap-2 px-4 py-1.5 rounded-md text-xs font-bold transition-all ${activeTab === 'fleet' ? 'bg-white dark:bg-white/10 text-green-600 dark:text-green-400 shadow-sm' : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-white'}`}
            >
              <Activity size={14} /> FLEET
            </button>
          </div>

          <div className="h-6 w-px bg-gray-200 dark:bg-white/10 ml-2"></div>
          <ThemeToggle />
        </div>

      </div>

      {/* CONTENT AREA - PASS ID DOWN */}
      <div className="flex-1 overflow-hidden relative">
        {activeTab === 'graph' && <GraphEditor graphId={currentGraphId} />}
        {activeTab === 'opt' && <Optimization graphId={currentGraphId} onDispatch={handleDispatch} />}
        {activeTab === 'fleet' && <FleetController graphId={currentGraphId} simulationRoutes={simulationRoutes} />}
      </div>
    </div>
  );
};

export default FleetInterface;