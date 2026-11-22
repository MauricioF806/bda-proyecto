SELECT c.relname, c.relkind, COALESCE(t.spcname, 'pg_default') AS tablespace
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE n.nspname = 'rrhh' AND c.relkind IN ('r','p','i','I')
ORDER BY c.relkind, c.relname;
