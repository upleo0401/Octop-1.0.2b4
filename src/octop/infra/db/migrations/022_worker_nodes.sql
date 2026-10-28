-- Schema v22 watermark. Desktop Worker nodes were removed (each PC runs
-- a full Octop runtime). Do not create worker_nodes on a fresh database.
UPDATE _schema_version SET version = 22;
