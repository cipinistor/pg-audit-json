CREATE EXTENSION "pg-audit-json";

-- Extract json for one key
SELECT jsonb_extract('{"a": 1, "b": 2, "c": 3}'::jsonb, '{a}'::text[]);

-- Extract json for multiple keys
SELECT jsonb_extract('{"a": 1, "b": 2, "c": 3}'::jsonb, '{a,c}'::text[]);

-- Extract json for no key 
SELECT jsonb_extract('{"a": 1, "b": 2, "c": 3}'::jsonb, '{}'::text[]);

DROP EXTENSION "pg-audit-json";
