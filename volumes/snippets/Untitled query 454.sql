INSERT INTO wh_edges (graph_id, node_a_id, node_b_id)                 
  SELECT                                                                
    c.graph_id,                                                         
    LEAST(cn.shelf_id, c.id),                                           
    GREATEST(cn.shelf_id, c.id)                                         
  FROM wh_nodes c                                                       
  JOIN wh_cell_nodes cn ON cn.id = c.id                                 
  WHERE c.type = 'cell'                                           
    AND c.graph_id = 1                                                  
    AND NOT EXISTS (                                              
      SELECT 1 FROM wh_edges e                                          
      WHERE e.graph_id = c.graph_id                                     
        AND ((e.node_a_id = cn.shelf_id AND e.node_b_id = c.id)
          OR (e.node_a_id = c.id AND e.node_b_id = cn.shelf_id))        
    );  