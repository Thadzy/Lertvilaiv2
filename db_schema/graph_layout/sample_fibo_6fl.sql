-- 1) Create warehouse and set depot location
DO $$
DECLARE
  v_graph_id bigint;
BEGIN
  v_graph_id := wh_create_graph('fibo_6fl');
  PERFORM set_config('wh.graph_id', v_graph_id::text, false);  -- false = session
END $$;

SELECT wh_update_depot_position(current_setting('wh.graph_id')::bigint, 0.0, 3.672);
SELECT wh_update_node_tag_id(current_setting('wh.graph_id')::bigint, '__depot__'::text, '5'::text);

-- 2) Create level {653.0, 1073.0, 1493.0, 1913.0};
SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L1', 0.850);
SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L2', 1.250);
SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L3', 1.650);
-- SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L4', 1.913);

-- 3) Create conveyors ( No conveyors )
-- SELECT wh_create_conveyor(current_setting('wh.graph_id')::bigint, -3, 2, 1.0, 'I');
-- SELECT wh_create_conveyor(current_setting('wh.graph_id')::bigint, 8, 2, 1.2, 'O');



-- 4) Create waypoints
-- public.wh_create_waypoint(
--   p_graph_id bigint,
--   p_x        real,
--   p_y        real,
--   p_alias    text DEFAULT NULL,
--   p_tag_id   text DEFAULT NULL
-- )

SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.0, 0.0, 'Q1'::text, '1'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.0, 0.918, 'Q2'::text, '2'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.0, 1.836, 'Q3'::text, '3'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.0, 2.754, 'Q4'::text, '4'::text);
-- SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.0, 3.672, 'Q5'::text, '5'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.612, 0.0, 'Q6'::text, '6'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.612, 0.918, 'Q7'::text, '7'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.612, 1.836, 'Q8'::text, '8'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.612, 2.754, 'Q9'::text, '9'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 0.612, 3.672, 'Q10'::text, '10'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.216, 0.0, 'Q11'::text, '11'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.216, 0.918, 'Q12'::text, '12'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.216, 1.836, 'Q13'::text, '13'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.216, 2.754, 'Q14'::text, '14'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.216, 3.672, 'Q15'::text, '15'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.836, 0.0, 'Q16'::text, '16'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.836, 0.918, 'Q17'::text, '17'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.836, 1.836, 'Q18'::text, '18'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.836, 2.754, 'Q19'::text, '19'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.836, 3.672, 'Q20'::text, '20'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.448, 0.0, 'Q21'::text, '21'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.448, 0.918, 'Q22'::text, '22'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.448, 1.836, 'Q23'::text, '23'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.448, 2.754, 'Q24'::text, '24'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.448, 3.672, 'Q25'::text, '25'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.181, -1.357, 'Q140'::text, '140'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.181, -2.275, 'Q71'::text, '71'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.114, -2.275, 'Q145'::text, '145'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.974, -2.275, 'Q122'::text, '122'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.974, -3.802, 'Q125'::text, '125'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.974, -4.827, 'Q146'::text, '146'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.974, -6.61, 'Q134'::text, '134'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 4.741, -2.275, 'Q119'::text, '119'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 4.741, -4.111, 'Q144'::text, '144'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 4.766, -4.822, 'Q133'::text, '133'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 4.741, -3.193, 'Q124'::text, '124'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 7.189, -2.275, 'Q121'::text, '121'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 10.555, -2.275, 'Q108'::text, '108'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 13.0, -2.275, 'Q114'::text, '114'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.181, -3.193, 'Q52'::text, '52'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.181, -4.815, 'Q53'::text, '53'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 4.436, -2.275, 'Q64'::text, '64'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 3.817, -2.275, 'Q139'::text, '139'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.974, -3.193, 'Q63'::text, '63'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 2.596, -2.275, 'Q59'::text, '59'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.181, -2.477, 'Q65'::text, '65'::text);
SELECT public.wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1.181, -4.111, 'Q58'::text, '58'::text);

-- 5) Create shelves
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 0.181, -5.168, 'S1C1');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 0.181, -5.693, 'S1C2');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 0.181, -6.218, 'S1C3');

SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 1.974, -5.180, 'S2C1');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 1.974, -5.705, 'S2C2');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 1.974, -6.215, 'S2C3');

SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 3.766, -5.175, 'S3C1');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 3.766, -5.700, 'S3C2');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 3.766, -6.225, 'S3C3');

SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 3.974, -6.963, 'S4C1');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 3.974, -7.488, 'S4C2');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 3.974, -8.013, 'S4C3');

-- 6) Create cells
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C1', 'L1', 'S1C1L1', 'S001C1L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C1', 'L2', 'S1C1L2', 'S001C1L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C1', 'L3', 'S1C1L3', 'S001C1L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C2', 'L1', 'S1C2L1', 'S001C2L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C2', 'L2', 'S1C2L2', 'S001C2L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C2', 'L3', 'S1C2L3', 'S001C2L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C3', 'L1', 'S1C3L1', 'S001C3L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C3', 'L2', 'S1C3L2', 'S001C3L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1C3', 'L3', 'S1C3L3', 'S001C3L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C1', 'L1', 'S2C1L1', 'S002C1L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C1', 'L2', 'S2C1L2', 'S002C1L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C1', 'L3', 'S2C1L3', 'S002C1L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C2', 'L1', 'S2C2L1', 'S002C2L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C2', 'L2', 'S2C2L2', 'S002C2L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C2', 'L3', 'S2C2L3', 'S002C2L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C3', 'L1', 'S2C3L1', 'S002C3L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C3', 'L2', 'S2C3L2', 'S002C3L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2C3', 'L3', 'S2C3L3', 'S002C3L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C1', 'L1', 'S3C1L1', 'S003C1L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C1', 'L2', 'S3C1L2', 'S003C1L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C1', 'L3', 'S3C1L3', 'S003C1L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C2', 'L1', 'S3C2L1', 'S003C2L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C2', 'L2', 'S3C2L2', 'S003C2L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C2', 'L3', 'S3C2L3', 'S003C2L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C3', 'L1', 'S3C3L1', 'S003C3L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C3', 'L2', 'S3C3L2', 'S003C3L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3C3', 'L3', 'S3C3L3', 'S003C3L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C1', 'L1', 'S4C1L1', 'S004C1L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C1', 'L2', 'S4C1L2', 'S004C1L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C1', 'L3', 'S4C1L3', 'S004C1L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C2', 'L1', 'S4C2L1', 'S004C2L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C2', 'L2', 'S4C2L2', 'S004C2L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C2', 'L3', 'S4C2L3', 'S004C2L3');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C3', 'L1', 'S4C3L1', 'S004C3L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C3', 'L2', 'S4C3L2', 'S004C3L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4C3', 'L3', 'S4C3L3', 'S004C3L3');

-- 7) Connect with edges
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, '__depot__', 'Q10');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q10', 'Q15');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q15', 'Q20');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q20', 'Q25');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q4', 'Q9');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q9', 'Q14');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q14', 'Q19');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q19', 'Q24');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q3', 'Q8');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q8', 'Q13');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q13', 'Q18');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q18', 'Q23');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q2', 'Q7');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q7', 'Q12');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q12', 'Q17');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q17', 'Q22');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q1', 'Q6');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q6', 'Q11');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q11', 'Q16');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q16', 'Q21');

-- Vertical connections (same x, adjacent y)
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q1', 'Q2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q2', 'Q3');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q3', 'Q4');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q4', '__depot__');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q6', 'Q7');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q7', 'Q8');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q8', 'Q9');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q9', 'Q10');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q11', 'Q12');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q12', 'Q13');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q13', 'Q14');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q14', 'Q15');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q16', 'Q17');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q17', 'Q18');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q18', 'Q19');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q19', 'Q20');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q21', 'Q22');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q22', 'Q23');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q23', 'Q24');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q24', 'Q25');
--- End the grid

--- To soi 3
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q11', 'Q140');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q140', 'Q71');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q71', 'Q65');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q65', 'Q52');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q52', 'Q58');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q58', 'Q53');


--- main branch
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q71', 'Q145');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q145', 'Q59');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q59', 'Q122');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q122', 'Q139');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q139', 'Q64');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q64', 'Q119');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q119', 'Q121');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q121', 'Q108');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q108', 'Q114');

-- soi 2
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q122', 'Q63');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q63', 'Q125');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q125', 'Q146');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q146', 'Q134');

-- soi 1
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q119', 'Q124');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q124', 'Q144');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q144', 'Q133');


-- To shelves
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q53', 'S1C1');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q53', 'S1C2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q53', 'S1C3');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q146', 'S2C1');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q146', 'S2C2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q146', 'S2C3');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q133', 'S3C1');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q133', 'S3C2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q133', 'S3C3');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q134', 'S4C1');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q134', 'S4C2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'Q134', 'S4C3');

--- One shelf should be accessed from only one place for now
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W7', 'S1');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W8', 'S2');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W9', 'S3');

-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W7', 'S4');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W8', 'S5');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W9', 'S6');

-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W12', 'S4');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W13', 'S5');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W14', 'S6');

-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'I', 'W1');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W1', 'W6');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W6', 'W11');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W11', 'O');

-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W5', 'W10');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W10', 'W15');

-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W10', '__depot__');


-- 8) Find shortest path
-- SELECT set_config('wh.graph_id', '10', false);
-- SELECT current_setting('wh.graph_id');

-- SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W3', 'W13');
-- SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'I', 'O');
-- SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W8', 'W15');
-- SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'O', 'W4');
-- SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W2', 'W14');
-- SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'S3L3', 'S5L2');

-- WITH p AS (
--   SELECT node_id, ord
--   FROM unnest(wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W3', 'W13')) WITH ORDINALITY AS u(node_id, ord)
-- )
-- SELECT array_agg(n.alias ORDER BY p.ord) AS alias_path
-- FROM p
-- JOIN public.wh_nodes n
--   ON n.id = p.node_id
--  AND n.graph_id = current_setting('wh.graph_id')::bigint;

-- WITH p AS (
--   SELECT node_id, ord
--   FROM unnest(wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'S3L3', 'S5L2')) WITH ORDINALITY AS u(node_id, ord)
-- )
-- SELECT array_agg(n.alias ORDER BY p.ord) AS alias_path
-- FROM p
-- JOIN public.wh_nodes n
--   ON n.id = p.node_id
--  AND n.graph_id = current_setting('wh.graph_id')::bigint;

-- Returns: {4, 5, 6}  (entrance → shelf → cell)