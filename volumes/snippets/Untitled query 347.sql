  SELECT n.id, n.type, n.alias                                          
  FROM wh_nodes_view n
  WHERE n.graph_id = 1                                                  
    AND n.id NOT IN (                                             
      SELECT node_a_id FROM wh_edges WHERE graph_id = 1                 
      UNION                                                             
      SELECT node_b_id FROM wh_edges WHERE graph_id = 1
    )                                                                   
  ORDER BY n.id; 