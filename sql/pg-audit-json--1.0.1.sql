--
-- An audit history is important on most tables. Provide an audit trigger that
-- logs to a dedicated audit table for the major relations.
--

-- Complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg-audit-json" to load this file. \quit

--
-- Implements missing "-" JSONB operators that are available in HSTORE
--

--
-- Implements "JSONB- TEXT[]" operation to remove a list of keys
--
-- Note: This method will be a supported operation of PostgreSQL 10
--
-- Credit:
-- http://schinckel.net/2014/09/29/adding-json%28b%29-operators-to-postgresql/
--
CREATE OR REPLACE FUNCTION "jsonb_minus" ( "left" JSONB, "keys" TEXT[] )
	RETURNS JSONB
	LANGUAGE SQL
	IMMUTABLE
	STRICT
AS $$
	SELECT
		CASE
			WHEN "left" ?| "keys"
				THEN COALESCE(
					(SELECT ('{' ||
										string_agg(to_json("key")::TEXT || ':' || "value", ',') ||
										'}')
						 FROM jsonb_each("left")
						WHERE "key" <> ALL ("keys")),
					'{}'
				)::JSONB
			ELSE "left"
		END
$$;

CREATE OPERATOR - (
	LEFTARG = JSONB,
	RIGHTARG = TEXT[],
	PROCEDURE = jsonb_minus
);

COMMENT ON FUNCTION jsonb_minus(JSONB, TEXT[]) IS 'Delete specified keys';

COMMENT ON OPERATOR - (JSONB, TEXT[]) IS 'Delete specified keys';

--
-- Implements "JSONB- JSONB" operation to recursively delete matching pairs.
--
-- Credit:
-- http://coussej.github.io/2016/05/24/A-Minus-Operator-For-PostgreSQLs-JSONB/
--

CREATE OR REPLACE FUNCTION "jsonb_minus" ( "left" JSONB, "right" JSONB )
	RETURNS JSONB
	LANGUAGE SQL
	IMMUTABLE
	STRICT
AS $$
	SELECT
		COALESCE(json_object_agg(
			"key",
			CASE
				-- if the value is an object and the value of the second argument is
				-- not null, we do a recursion
				WHEN jsonb_typeof("value") = 'object' AND "right" -> "key" IS NOT NULL
				THEN jsonb_minus("value", "right" -> "key")
				-- for all the other types, we just return the value
				ELSE "value"
			END
		), '{}')::JSONB
	FROM
		jsonb_each("left")
	WHERE
		"left" -> "key" <> "right" -> "key"
		OR "right" -> "key" IS NULL
$$;

CREATE OPERATOR - (
	LEFTARG   = JSONB,
	RIGHTARG  = JSONB,
	PROCEDURE = jsonb_minus
);

COMMENT ON FUNCTION jsonb_minus(JSONB, JSONB)
	IS 'Delete matching pairs in the right argument from the left argument';

COMMENT ON OPERATOR - (JSONB, JSONB)
	IS 'Delete matching pairs in the right argument from the left argument';

CREATE OR REPLACE FUNCTION "table_pk_columns" ( table_id REGCLASS )
	RETURNS TEXT[]
	LANGUAGE SQL
	IMMUTABLE
	STRICT
AS $$
	SELECT
		array_agg(a.attname)::TEXT[]
	FROM
		pg_index i
		JOIN pg_attribute a ON
		(
			a.attrelid = i.indrelid AND
			a.attnum = ANY(i.indkey)
		)
	WHERE
		i.indrelid = table_id AND
		i.indisprimary
$$;

CREATE OR REPLACE FUNCTION "jsonb_extract" ( json_data JSONB, keys TEXT[] )
	RETURNS JSONB
	LANGUAGE SQL
	IMMUTABLE
	STRICT
AS $$
	SELECT
		json_object_agg(
			key,
			json_data #> ARRAY[key]
		)::JSONB
	FROM
		unnest(keys) AS key
$$;


CREATE SCHEMA audit;
REVOKE ALL ON SCHEMA audit FROM public;
COMMENT ON SCHEMA audit
	IS 'Out-of-table audit/history logging tables and trigger functions';

--
-- Audited data. Lots of information is available, it's just a matter of how
-- much you really want to record. See:
--
--   http://www.postgresql.org/docs/9.1/static/functions-info.html
--
-- Remember, every column you add takes up more audit table space and slows
-- audit inserts.
--
-- Every index you add has a big impact too, so avoid adding indexes to the
-- audit table unless you REALLY need them. The hstore GIST indexes are
-- particularly expensive.
--
-- It is sometimes worth copying the audit table, or a coarse subset of it that
-- you're interested in, into a temporary table where you CREATE any useful
-- indexes and do your analysis.
--
CREATE TABLE audit.log (
		id BIGSERIAL PRIMARY KEY,
		schema_name TEXT NOT NULL,
		table_name TEXT NOT NULL,
		action TEXT NOT NULL CHECK (action IN ('I','D','U', 'T')),
		row_pk JSONB,
		old_values JSONB,
		new_values JSONB,
		client_query TEXT,
		relid OID NOT NULL,
		session_user_name TEXT NOT NULL,
		current_user_name TEXT NOT NULL,
		action_tstamp_tx TIMESTAMP WITH TIME ZONE NOT NULL,
		action_tstamp_stm TIMESTAMP WITH TIME ZONE NOT NULL,
		action_tstamp_clk TIMESTAMP WITH TIME ZONE NOT NULL,
		transaction_id BIGINT NOT NULL,
		application_name TEXT,
		application_user_name TEXT,
		client_addr INET,
		client_port INTEGER
);

REVOKE ALL ON audit.log FROM public;

COMMENT ON TABLE audit.log
	IS 'History of auditable actions on audited tables';
COMMENT ON COLUMN audit.log.id
	IS 'Unique identifier for each auditable event';
COMMENT ON COLUMN audit.log.schema_name
	IS 'Database schema audited table for this event is in';
COMMENT ON COLUMN audit.log.table_name
	IS 'Non-schema-qualified table name of table event occured in';
COMMENT ON COLUMN audit.log.action
	IS 'Action type; I = insert, D = delete, U = update, T = truncate';
COMMENT ON COLUMN audit.log.row_pk
	IS 'PK identifying the row affected by INSERT / UPDATE / DELETE. For TRUNCATE this is null.';
COMMENT ON COLUMN audit.log.old_values
	IS 'Old values of fields changed by UPDATE, or full row for DELETE. For INSERT / TRUNCATE this is null.';
COMMENT ON COLUMN audit.log.new_values
	IS 'New values of fields changed by UPDATE. For DELETE / INSERT / TRUNCATE this is null.';
COMMENT ON COLUMN audit.log.client_query
	IS 'Top-level query that caused this auditable event. May be more than one.';
COMMENT ON COLUMN audit.log.relid
	IS 'Table OID. Changes with drop/create. Get with ''tablename''::REGCLASS';
COMMENT ON COLUMN audit.log.session_user_name
	IS 'Login / session user whose statement caused the audited event';
COMMENT ON COLUMN audit.log.current_user_name
	IS 'Effective user that cased audited event (if authorization level changed)';
COMMENT ON COLUMN audit.log.action_tstamp_tx
	IS 'Transaction start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.log.action_tstamp_stm
	IS 'Statement start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.log.action_tstamp_clk
	IS 'Wall clock time at which audited event''s trigger call occurred';
COMMENT ON COLUMN audit.log.transaction_id
	IS 'Identifier of transaction that made the change. Unique when paired with action_tstamp_tx.';
COMMENT ON COLUMN audit.log.client_addr
	IS 'IP address of client that issued query. Null for unix domain socket.';
COMMENT ON COLUMN audit.log.client_port
	IS 'Port address of client that issued query. Undefined for unix socket.';
COMMENT ON COLUMN audit.log.application_name
	IS 'Client-set session application name when this audit event occurred.';
COMMENT ON COLUMN audit.log.application_user_name
	IS 'Client-set session application user when this audit event occurred.';

CREATE INDEX idx_log_relid ON audit.log(relid);
CREATE INDEX idx_log_action_tstamp_stm ON audit.log(action_tstamp_stm);
CREATE INDEX idx_log_action ON audit.log(action);

--
-- Allow the user of the extension to create a backup of the audit log data
--
SELECT pg_catalog.pg_extension_config_dump('audit.log', '');

CREATE OR REPLACE FUNCTION audit.if_modified_func()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
		audit_row audit.log;
		old_values JSONB;
		new_values JSONB;
		pk_cols TEXT[] = ARRAY[]::TEXT[];
		excluded_cols TEXT[] = ARRAY[]::TEXT[];
BEGIN
	IF TG_WHEN <> 'AFTER' THEN
		RAISE EXCEPTION 'audit.if_modified_func() may only run as an AFTER trigger';
	END IF;

	audit_row = ROW(
		nextval('audit.log_id_seq'),										-- id
		TG_TABLE_SCHEMA::TEXT,													-- schema_name
		TG_TABLE_NAME::TEXT,														-- table_name
		substring(TG_OP, 1, 1),													-- action
		NULL,																						-- pk
		NULL,																						-- old
		NULL,																						-- new
		current_query(),																-- top-level query or queries
		TG_RELID,																				-- relation OID for faster searches
		session_user::TEXT,															-- session_user_name
		current_user::TEXT,															-- current_user_name
		current_timestamp,															-- action_tstamp_tx
		statement_timestamp(),													-- action_tstamp_stm
		clock_timestamp(),															-- action_tstamp_clk
		txid_current(),																	-- transaction ID
		current_setting('audit.application_name', true),			-- client application
		current_setting('audit.application_user_name', true),	-- client user name
		inet_client_addr(),															-- client_addr
		inet_client_port()															-- client_port
		);

	pk_cols = TG_ARGV[0]::TEXT[];

	IF NOT TG_ARGV[1]::BOOLEAN IS DISTINCT FROM 'f'::BOOLEAN THEN
		audit_row.client_query = NULL;
	END IF;

	IF TG_ARGV[2] IS NOT NULL THEN
		excluded_cols = TG_ARGV[2]::TEXT[];
	END IF;


	IF (TG_OP = 'INSERT' AND TG_LEVEL = 'ROW') THEN
		new_values = to_jsonb(NEW.*);
		audit_row.row_pk = jsonb_extract(new_values, pk_cols);
	ELSIF (TG_OP = 'UPDATE' AND TG_LEVEL = 'ROW') THEN
		new_values = to_jsonb(NEW.*);
		old_values = to_jsonb(OLD.*);
		audit_row.new_values = (new_values - old_values) - excluded_cols;
		IF audit_row.new_values = '{}'::JSONB THEN
			-- All changed fields are ignored. Skip this update.
			RETURN NULL;
		ELSE
			audit_row.row_pk = jsonb_extract(old_values, pk_cols);
			audit_row.old_values = (old_values - new_values) - excluded_cols;
		END IF;
	ELSIF (TG_OP = 'DELETE' AND TG_LEVEL = 'ROW') THEN
		old_values = to_jsonb(OLD.*);
		audit_row.row_pk = jsonb_extract(old_values, pk_cols);
		audit_row.old_values = old_values - excluded_cols;
	ELSIF (TG_LEVEL = 'STATEMENT' AND TG_OP = 'TRUNCATE') THEN
		--on truncate, table is emptied, so there's nothing row-related to log
		audit_row.old_values = NULL;
	ELSE
		RAISE EXCEPTION '[audit.if_modified_func] - Trigger func added as trigger '
										'for unhandled case: %, %', TG_OP, TG_LEVEL;
		RETURN NULL;
	END IF;
	INSERT INTO audit.log VALUES (audit_row.*);
	RETURN NULL;
END;
$$;


COMMENT ON FUNCTION audit.if_modified_func() IS $$
Track changes to a table at the statement and/or row level.

Optional parameters to trigger in CREATE TRIGGER call:

param 0: TEXT[], primary key columns for identifying the audited row.

param 1: BOOLEAN, whether to log the query text. Default 't'.

param 1: TEXT[], columns to ignore in updates. Default [].

				 Updates to ignored cols are omitted from changed_fields.

				 Updates with only ignored cols changed are not inserted
				 into the audit log.

				 Almost all the processing work is still done for updates
				 that ignored. If you need to save the load, you need to use
				 WHEN clause on the trigger instead.

				 No warning or error is issued if ignored_cols contains columns
				 that do not exist in the target table. This lets you specify
				 a standard set of ignored columns.

There is no parameter to disable logging of values. Add this trigger as
a 'FOR EACH STATEMENT' rather than 'FOR EACH ROW' trigger if you do not
want to log row values.

Note that the user name logged is the login role for the session. The audit
trigger cannot obtain the active role because it is reset by
the SECURITY DEFINER invocation of the audit trigger its self.
$$;

---
--- Enables tracking on a table by generating and attaching a trigger
---
CREATE OR REPLACE FUNCTION audit.audit_table(
	target_table REGCLASS,
	audit_query_text BOOLEAN,
	ignored_cols TEXT[]
)
RETURNS VOID
LANGUAGE 'plpgsql'
AS $$
DECLARE
	pk_columns TEXT[];
	trigger_txt TEXT;
	_ignored_cols_snip TEXT = '';
BEGIN
	EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_row ON ' || target_table::TEXT;
	EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_stm ON ' || target_table::TEXT;

	pk_columns = table_pk_columns(target_table);

	IF array_length(pk_columns, 1) <= 0 THEN
		RAISE EXCEPTION '[audit.audit_table] - table must have PK, required for audit';
		--: %' target_table::TEXT;
	ELSE
		IF array_length(ignored_cols, 1) > 0 THEN
				_ignored_cols_snip = ', ' || quote_literal(ignored_cols);
		END IF;

		trigger_txt = 'CREATE TRIGGER audit_trigger_row '
			'AFTER INSERT OR UPDATE OR DELETE ON ' ||
			target_table::TEXT ||
			' FOR EACH ROW EXECUTE PROCEDURE audit.if_modified_func(' ||
			quote_literal(pk_columns) ||
			', ' || quote_literal(audit_query_text) ||
			_ignored_cols_snip || ');';

		RAISE NOTICE '%', trigger_txt;
		EXECUTE trigger_txt;

		trigger_txt = 'CREATE TRIGGER audit_trigger_stm AFTER TRUNCATE ON ' ||
			target_table::TEXT ||
			' FOR EACH STATEMENT EXECUTE PROCEDURE audit.if_modified_func(' ||
			quote_literal(pk_columns) ||
			', ' || quote_literal(audit_query_text) || ');';

		RAISE NOTICE '%', trigger_txt;
		EXECUTE trigger_txt;
	END IF;
END;
$$;

COMMENT ON FUNCTION audit.audit_table(REGCLASS, BOOLEAN, TEXT[]) IS $$
Add auditing support to a table.

Arguments:
	 target_table:     Table name, schema qualified if not on search_path
	 audit_query_text: Record the text of the client query that triggered
										 the audit event?
	 ignored_cols:     Columns to exclude from update diffs,
										 ignore updates that change only ignored cols.
$$;

--
-- Pg doesn't allow variadic calls with 0 params, so provide a wrapper
--
CREATE OR REPLACE FUNCTION audit.audit_table(
	target_table REGCLASS,
	audit_query_text BOOLEAN
)
RETURNS VOID
LANGUAGE SQL
AS $$
	SELECT audit.audit_table($1, $2, ARRAY[]::TEXT[]);
$$;

--
-- And provide a convenience call wrapper for the simplest case
-- of row-level logging with no excluded cols and query logging enabled.
--
CREATE OR REPLACE FUNCTION audit.audit_table(target_table REGCLASS)
RETURNS VOID
LANGUAGE 'sql'
AS $$
	SELECT audit.audit_table($1, BOOLEAN 't');
$$;

COMMENT ON FUNCTION audit.audit_table(REGCLASS) IS $$
Add auditing support to the given table. Row-level changes will be logged with
full client query text. No cols are ignored.
$$;
