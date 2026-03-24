docker exec -i wcs-db-1 psql -U postgres -c "
CREATE TABLE IF NOT EXISTS wh_cells (
    id SERIAL PRIMARY KEY,
    node_id INT,
    alias VARCHAR(50),
    level INT,
    status VARCHAR(50) DEFAULT 'available'
);
GRANT SELECT ON wh_cells TO anon, authenticated;
"