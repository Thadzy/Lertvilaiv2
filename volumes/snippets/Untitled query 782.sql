-- ตรวจสอบในตาราง Waypoint โดยตรง
SELECT * FROM public.wh_waypoint_nodes 
WHERE alias = 'Q119';

-- หรือดูผ่าน View ที่น่าจะรวมข้อมูลไว้ให้แล้ว
SELECT * FROM public.wh_nodes_detailed_view 
WHERE alias = 'Q119';