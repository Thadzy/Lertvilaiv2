-- 1. ดูว่ามี Graph ทั้งหมดกี่ใบ และใบไหนล่าสุด
SELECT id, name, created_at FROM public.wh_graphs ORDER BY id DESC;

-- 2. ดูว่า Q119 กระจัดกระจายอยู่กี่ Graph และมีพิกัดหรือไม่
SELECT id, graph_id, alias, x, y 
FROM public.wh_nodes_detailed_view 
WHERE alias = 'Q119';