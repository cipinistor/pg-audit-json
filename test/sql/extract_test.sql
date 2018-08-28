CREATE EXTENSION "pg-audit-json";

-- Extract json for one key
SELECT jsonb_extract('{"a": 1, "b": 2, "c": 3}'::jsonb, '{a}'::text[]);

-- Extract json for multiple keys
SELECT jsonb_extract('{"a": 1, "b": 2, "c": 3}'::jsonb, '{a,c}'::text[]);

DROP EXTENSION "pg-audit-json";
