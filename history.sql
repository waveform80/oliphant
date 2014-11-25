-------------------------------------------------------------------------------
-- HISTORY FRAMEWORK
-------------------------------------------------------------------------------
-- Copyright (c) 2014 Dave Hughes <dave@waveform.org.uk>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to
-- deal in the Software without restriction, including without limitation the
-- rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
-- sell copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
-- IN THE SOFTWARE.
-------------------------------------------------------------------------------
-- The following code is adapted from a Usenet posting, discussing methods of
-- tracking history via triggers:
--
-- http://groups.google.com/group/comp.databases.ibm-db2/msg/e84aeb1f6ac87e6c
--
-- Routines are provided for creating a table which will store the history of
-- a "master" table, and for creating triggers that will keep the history
-- populated as rows are manipulated in the master. Routines are also provided
-- for creating views providing commonly requested transformations of the
-- history such as "what changed when" and "snapshots over constant periods".
-------------------------------------------------------------------------------


-- ROLES
-------------------------------------------------------------------------------
-- The following roles grant usage and administrative rights to the objects
-- created by this module.
-------------------------------------------------------------------------------

CREATE ROLE UTILS_HISTORY_USER;
CREATE ROLE UTILS_HISTORY_ADMIN;

--GRANT UTILS_HISTORY_USER TO UTILS_USER;
GRANT UTILS_HISTORY_USER TO UTILS_HISTORY_ADMIN WITH ADMIN OPTION;
--GRANT UTILS_HISTORY_ADMIN TO UTILS_ADMIN WITH ADMIN OPTION;

-- SQLSTATES
-------------------------------------------------------------------------------
-- The following variables define the set of SQLSTATEs raised by the procedures
-- and functions in this module.
-------------------------------------------------------------------------------

--CREATE VARIABLE HISTORY_KEY_FIELDS_STATE CHAR(5) CONSTANT '90004';
--CREATE VARIABLE HISTORY_NO_PK_STATE CHAR(5) CONSTANT '90005';
--CREATE VARIABLE HISTORY_UPDATE_PK_STATE CHAR(5) CONSTANT '90006';
--
--GRANT READ ON VARIABLE HISTORY_KEY_FIELDS_STATE TO ROLE UTILS_HISTORY_USER;
--GRANT READ ON VARIABLE HISTORY_NO_PK_STATE TO ROLE UTILS_HISTORY_USER;
--GRANT READ ON VARIABLE HISTORY_UPDATE_PK_STATE TO ROLE UTILS_HISTORY_USER;
--GRANT READ ON VARIABLE HISTORY_KEY_FIELDS_STATE TO ROLE UTILS_HISTORY_ADMIN WITH GRANT OPTION;
--GRANT READ ON VARIABLE HISTORY_NO_PK_STATE TO ROLE UTILS_HISTORY_ADMIN WITH GRANT OPTION;
--GRANT READ ON VARIABLE HISTORY_UPDATE_PK_STATE TO ROLE UTILS_HISTORY_ADMIN WITH GRANT OPTION;
--
--COMMENT ON VARIABLE HISTORY_KEY_FIELDS_STATE
--    IS 'The SQLSTATE raised when a history sub-routine is called with something other than ''Y'' or ''N'' as the KEY_FIELDS parameter';
--
--COMMENT ON VARIABLE HISTORY_NO_PK_STATE
--    IS 'The SQLSTATE raised when an attempt is made to create a history table for a table without a primary key';
--
--COMMENT ON VARIABLE HISTORY_UPDATE_PK_STATE
--    IS 'The SQLSTATE raised when an attempt is made to update a primary key''s value in a table with an associated history table';

-- X_HISTORY_PERIODLEN(RESOLUTION)
-- X_HISTORY_PERIODSTEP(RESOLUTION)
-- X_HISTORY_PERIODSTEP(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EFFNAME(RESOLUTION)
-- X_HISTORY_EFFNAME(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EXPNAME(RESOLUTION)
-- X_HISTORY_EXPNAME(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EFFDEFAULT(RESOLUTION)
-- X_HISTORY_EFFDEFAULT(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_EXPDEFAULT(RESOLUTION)
-- X_HISTORY_EXPDEFAULT(SOURCE_SCHEMA, SOURCE_TABLE)
-- X_HISTORY_PERIODSTART(RESOLUTION, EXPRESSION)
-- X_HISTORY_PERIODEND(RESOLUTION, EXPRESSION)
-- X_HISTORY_EFFNEXT(RESOLUTION, OFFSET)
-- X_HISTORY_EXPPRIOR(RESOLUTION, OFFSET)
-- X_HISTORY_INSERT(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION, OFFSET)
-- X_HISTORY_EXPIRE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION, OFFSET)
-- X_HISTORY_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION)
-- X_HISTORY_UPDATE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION)
-- X_HISTORY_CHECK(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, RESOLUTION)
-- X_HISTORY_CHANGES(SOURCE_SCHEMA, SOURCE_TABLE, RESOLUTION)
-- X_HISTORY_SNAPSHOTS(SOURCE_SCHEMA, SOURCE_TABLE, RESOLUTION)
-- X_HISTORY_UPDATE_FIELDS(SOURCE_SCHEMA, SOURCE_TABLE, KEY_FIELDS)
-- X_HISTORY_UPDATE_WHEN(SOURCE_SCHEMA, SOURCE_TABLE, KEY_FIELDS)
-------------------------------------------------------------------------------
-- These functions are effectively private utility subroutines for the
-- procedures defined below. They simply generate snippets of SQL given a set
-- of input parameters.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION x_history_periodlen(resolution VARCHAR(12))
    RETURNS INTERVAL
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE resolution
        WHEN 'quarter' THEN interval '3 months'
        WHEN 'millennium' THEN interval '1000 years'
        ELSE CAST('1 ' || resolution AS INTERVAL)
    END);
$$;

CREATE OR REPLACE FUNCTION x_history_periodstep(resolution VARCHAR(12))
    RETURNS INTERVAL
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
        THEN INTERVAL '1 day'
        ELSE INTERVAL '1 microsecond'
    END);
$$;

CREATE OR REPLACE FUNCTION x_history_periodstep(source_schema NAME, source_table NAME)
    RETURNS INTERVAL
    LANGUAGE SQL
    STABLE
AS $$
    VALUES (CASE (
            SELECT format_type(atttypid, NULL)
            FROM pg_catalog.pg_attribute
            WHERE
                attrelid = CAST(
                    quote_ident(source_schema) || '.' || quote_ident(source_table)
                    AS regclass)
                AND attnum = 1
            )
        WHEN 'timestamp without time zone' THEN INTERVAL '1 microsecond'
        WHEN 'timestamp with time zone' THEN INTERVAL '1 microsecond'
        WHEN 'date' THEN INTERVAL '1 day'
    END);
$$;

CREATE OR REPLACE FUNCTION x_history_effname(resolution VARCHAR(12))
    RETURNS NAME
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CAST('effective' AS name));
$$;

CREATE OR REPLACE FUNCTION x_history_effname(source_schema NAME, source_table NAME)
    RETURNS NAME
    LANGUAGE SQL
    STABLE
AS $$
    SELECT attname
    FROM pg_catalog.pg_attribute
    WHERE
        attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND attnum = 1;
$$;

CREATE OR REPLACE FUNCTION x_history_expname(resolution VARCHAR(12))
    RETURNS NAME
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (CAST('expiry' AS NAME));
$$;

CREATE OR REPLACE FUNCTION x_history_expname(source_schema NAME, source_table NAME)
    RETURNS NAME
    LANGUAGE SQL
    STABLE
AS $$
    SELECT attname
    FROM pg_catalog.pg_attribute
    WHERE
        attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND attnum = 2;
$$;

CREATE OR REPLACE FUNCTION x_history_effdefault(resolution VARCHAR(12))
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
            THEN 'current_date'
            ELSE 'current_timestamp'
        END);
$$;

CREATE OR REPLACE FUNCTION x_history_effdefault(source_schema NAME, source_table NAME)
    RETURNS TEXT
    LANGUAGE SQL
    STABLE
AS $$
    SELECT d.adsrc
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = a.attrelid
            AND d.adnum = a.attnum
    WHERE
        a.attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND a.attnum = 1;
$$;

CREATE OR REPLACE FUNCTION x_history_expdefault(resolution VARCHAR(12))
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        CASE WHEN x_history_periodlen(resolution) >= INTERVAL '1 day'
            THEN 'DATE ''9999-12-31'''
            ELSE 'TIMESTAMP ''9999-12-31 23:59:59.999999'''
        END);
$$;

CREATE OR REPLACE FUNCTION x_history_expdefault(source_schema name, source_table name)
    RETURNS text
    LANGUAGE SQL
    STABLE
AS $$
    SELECT d.adsrc
    FROM
        pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = a.attrelid
            AND d.adnum = a.attnum
    WHERE
        a.attrelid = CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass)
        AND a.attnum = 2;
$$;

CREATE OR REPLACE FUNCTION x_history_periodstart(resolution VARCHAR(12), expression TEXT)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        'date_trunc(' || quote_literal(resolution) || ', ' || expression || ')'
    );
$$;

CREATE OR REPLACE FUNCTION x_history_periodend(resolution VARCHAR(12), expression TEXT)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        'date_trunc(' || quote_literal(resolution) || ', ' || expression || ') + '
        || 'INTERVAL ' || quote_literal(x_history_periodlen(resolution)) || ' - '
        || 'INTERVAL ' || quote_literal(x_history_periodstep(resolution))
    );
$$;

CREATE OR REPLACE FUNCTION x_history_effnext(resolution VARCHAR(12), shift INTERVAL)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        x_history_periodstart(
            resolution, x_history_effdefault(resolution)
            || CASE WHEN shift IS NOT NULL
                THEN ' + INTERVAL ' || quote_literal(shift)
                ELSE ''
            END)
    );
$$;

CREATE OR REPLACE FUNCTION x_history_expprior(resolution VARCHAR(12), shift INTERVAL)
    RETURNS TEXT
    LANGUAGE SQL
    IMMUTABLE
AS $$
    VALUES (
        x_history_periodend(
            resolution, x_history_effdefault(resolution)
            || ' - INTERVAL ' || quote_literal(x_history_periodlen(resolution))
            || CASE WHEN shift IS NOT NULL
                THEN ' + INTERVAL ' || quote_literal(shift)
                ELSE ''
            END)
    );
$$;

CREATE OR REPLACE FUNCTION x_history_insert(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    insert_stmt TEXT DEFAULT '';
    values_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    insert_stmt := 'INSERT INTO ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '(';
    values_stmt = ' VALUES (';
    insert_stmt := insert_stmt || quote_ident(x_history_effname(dest_schema, dest_table));
    values_stmt := values_stmt || x_history_effnext(resolution, shift);
    FOR r IN
        SELECT attname
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 0
        ORDER BY attnum
    LOOP
        insert_stmt := insert_stmt || ',' || quote_ident(r.attname);
        values_stmt := values_stmt || ',NEW.' || quote_ident(r.attname);
    END LOOP;
    insert_stmt := insert_stmt || ')';
    values_stmt := values_stmt || ')';
    RETURN insert_stmt || values_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_expire(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    update_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    update_stmt := 'UPDATE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || ' SET '   || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expprior(resolution, shift)
        || ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
    LOOP
        update_stmt := update_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN update_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_update(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    update_stmt TEXT DEFAULT '';
    set_stmt TEXT DEFAULT '';
    where_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    update_stmt := 'UPDATE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' ';
    where_stmt := ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname, ARRAY [att.attnum] <@ con.conkey AS iskey
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
    LOOP
        IF r.iskey THEN
            where_stmt := where_stmt
                || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
        ELSE
            set_stmt := set_stmt
                || ', ' || quote_ident(r.attname) || ' = NEW.' || quote_ident(r.attname);
        END IF;
    END LOOP;
    set_stmt = 'SET' || substring(set_stmt from 2);
    RETURN update_stmt || set_stmt || where_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_delete(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    delete_stmt TEXT DEFAULT '';
    where_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    delete_stmt = 'DELETE FROM ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table);
    where_stmt = ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        where_stmt := where_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN delete_stmt || where_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_check(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt TEXT DEFAULT '';
    where_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    select_stmt :=
        'SELECT ' || x_history_periodend(resolution, x_history_effname(dest_schema, dest_table))
        || ' FROM ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table);
    where_stmt :=
        ' WHERE ' || quote_ident(x_history_expname(dest_schema, dest_table)) || ' = ' || x_history_expdefault(resolution);
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND att.attnum > 0
            AND con.contype = 'p'
            AND ARRAY [att.attnum] <@ con.conkey
    LOOP
        where_stmt := where_stmt
            || ' AND ' || quote_ident(r.attname) || ' = OLD.' || quote_ident(r.attname);
    END LOOP;
    RETURN select_stmt || where_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_changes(
    source_schema NAME,
    source_table NAME
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt TEXT DEFAULT '';
    from_stmt TEXT DEFAULT '';
    insert_test TEXT DEFAULT '';
    update_test TEXT DEFAULT '';
    delete_test TEXT DEFAULT '';
    r RECORD;
BEGIN
    from_stmt :=
        ' FROM ' || quote_ident('old_' || source_table) || ' AS old'
        || ' FULL JOIN ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' AS new'
        || ' ON new.' || x_history_effname(source_schema, source_table) || ' - INTERVAL ' || quote_literal(x_history_periodstep(source_schema, source_table))
        || ' BETWEEN old.' || x_history_effname(source_schema, source_table)
        || ' AND old.' || x_history_expname(source_schema, source_table);
    FOR r IN
        SELECT att.attname, ARRAY [att.attnum] <@ con.conkey AS iskey
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 2
    LOOP
        select_stmt := select_stmt
            || ', old.' || quote_ident(r.attname) || ' AS ' || quote_ident('old_' || r.attname)
            || ', new.' || quote_ident(r.attname) || ' AS ' || quote_ident('new_' || r.attname);
        IF r.iskey THEN
            from_stmt := from_stmt
                || ' AND old.' || quote_ident(r.attname) || ' = new.' || quote_ident(r.attname);
            insert_test := insert_test
                || 'AND old.' || quote_ident(r.attname) || ' IS NULL '
                || 'AND new.' || quote_ident(r.attname) || ' IS NOT NULL ';
            update_test := update_test
                || 'AND old.' || quote_ident(r.attname) || ' IS NOT NULL '
                || 'AND new.' || quote_ident(r.attname) || ' IS NOT NULL ';
            delete_test := delete_test
                || 'AND old.' || quote_ident(r.attname) || ' IS NOT NULL '
                || 'AND new.' || quote_ident(r.attname) || ' IS NULL ';
        END IF;
    END LOOP;
    select_stmt :=
        'SELECT'
        || ' coalesce(new.'
            || quote_ident(x_history_effname(source_schema, source_table)) || ', old.'
            || quote_ident(x_history_expname(source_schema, source_table)) || ' + INTERVAL ' || quote_literal(x_history_periodstep(source_schema, source_table)) || ') AS changed'
        || ', CAST(CASE '
            || 'WHEN' || substring(insert_test from 4) || 'THEN ''INSERT'' '
            || 'WHEN' || substring(update_test from 4) || 'THEN ''UPDATE'' '
            || 'WHEN' || substring(delete_test from 4) || 'THEN ''DELETE'' '
            || 'ELSE ''ERROR'' END AS CHAR(6)) AS change'
        || SELECT_STMT;
    RETURN
        'WITH ' || quote_ident('old_' || source_table) || ' AS ('
        || '    SELECT *'
        || '    FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table)
        || '    WHERE ' || x_history_expname(source_schema, source_table) || ' < ' || x_history_expdefault(source_schema, source_table)
        || ') '
        || select_stmt
        || from_stmt;
END;
$$;

CREATE OR REPLACE FUNCTION x_history_snapshots(
    source_schema NAME,
    source_table NAME,
    resolution VARCHAR(12)
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    select_stmt TEXT DEFAULT '';
    r RECORD;
BEGIN
    select_stmt :=
        'WITH RECURSIVE range(at) AS ('
        || '    SELECT min(' || quote_ident(x_history_effname(source_schema, source_table)) || ')'
        || '    FROM ' || quote_ident(source_schema) || '.' || quote_ident(source_table)
        || '    UNION ALL'
        || '    SELECT at + ' || x_history_periodlen(resolution)
        || '    FROM range'
        || '    WHERE at <= ' || x_history_effdefault(resolution)
        || ') '
        || 'SELECT ' || x_history_periodend(resolution, 'r.at') || ' AS snapshot';
    FOR r IN
        SELECT attname
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 2
        ORDER BY attnum
    LOOP
        select_stmt := select_stmt
            || ', h.' || quote_ident(r.attname);
    END LOOP;
    RETURN select_stmt
        || ' FROM range r JOIN ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' H'
        || ' ON r.at BETWEEN h.' || quote_ident(x_history_effname(source_schema, source_table))
        || ' AND h.' || quote_ident(x_history_expname(source_schema, source_table));
END;
$$;

CREATE OR REPLACE FUNCTION x_history_update_fields(
    source_schema NAME,
    source_table NAME,
    key_fields BOOLEAN
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    result TEXT DEFAULT '';
    r RECORD;
BEGIN
    FOR r IN
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND (
                (key_fields AND ARRAY [att.attnum] <@ con.conkey) OR
                NOT (key_fields OR ARRAY [att.attnum] <@ con.conkey)
            )
        ORDER BY att.attnum
    LOOP
        result := result || ',' || quote_ident(r.attname);
    END LOOP;
    RETURN substring(result from 2);
END;
$$;

CREATE OR REPLACE FUNCTION x_history_update_when(
    source_schema NAME,
    source_table NAME,
    key_fields BOOLEAN
)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    result TEXT DEFAULT '';
    r RECORD;
BEGIN
    FOR r IN
        SELECT att.attname, att.attnotnull
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
            AND (
                (key_fields AND ARRAY [att.attnum] <@ con.conkey) OR
                NOT (key_fields OR ARRAY [att.attnum] <@ con.conkey)
            )
        ORDER BY att.attnum
    LOOP
        result := result
            || ' OR old.' || quote_ident(r.attname) || ' <> new.' || quote_ident(r.attname);
        IF NOT r.attnotnull THEN
            result := result
                || ' OR (old.' || quote_ident(r.attname) || ' IS NULL AND new.' || quote_ident(r.attname) || ' IS NOT NULL)'
                || ' OR (new.' || quote_ident(r.attname) || ' IS NULL AND old.' || quote_ident(r.attname) || ' IS NOT NULL)';
        END IF;
    END LOOP;
    RETURN substring(result from 5);
END;
$$;

-- create_history_table(source_schema, source_table, dest_schema, dest_table, dest_tbspace, resolution)
-- create_history_table(source_table, dest_table, dest_tbspace, resolution)
-- create_history_table(source_table, dest_table, resolution)
-- create_history_table(source_table, resolution)
-------------------------------------------------------------------------------
-- The create_history_table procedure creates, from a template table specified
-- by source_schema and source_table, another table named by dest_schema and
-- dest_table designed to hold a representation of the source table's content
-- over time.  Specifically, the destination table has the same structure as
-- source table, but with two additional columns named "effective" and "expiry"
-- which occur before all other original columns. The primary key of the source
-- table, in combination with "effective" will form the primary key of the
-- destination table, and a unique index involving the primary key and the
-- "expiry" column will also be created as this provides better performance of
-- the triggers used to maintain the destination table.
--
-- The dest_tbspace parameter identifies the tablespace used to store the new
-- table's data. If dest_tbspace is not specified, it defaults to the
-- tablespace of the source table. If dest_table is not specified it defaults
-- to the value of source_table with "_history" as a suffix. If dest_schema and
-- source_schema are not specified they default to the current schema.
--
-- The resolution parameter determines the smallest unit of time that a history
-- record can cover. See the create_history_trigger documentation for a list of
-- the possible values.
--
-- All SELECT and CONTROL authorities present on the source table will be
-- copied to the destination table. However, INSERT, UPDATE and DELETE
-- authorities are excluded as these operations should only ever be performed
-- by the history maintenance triggers themselves.
--
-- If the specified table already exists, this procedure will replace it,
-- potentially losing all its content. If the existing history data is
-- important to you, make sure you back it up before executing this procedure.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_history_table(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    dest_tbspace NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    key_name NAME DEFAULT '';
    key_cols TEXT DEFAULT '';
    ddl TEXT DEFAULT '';
    r RECORD;
BEGIN
    --CALL ASSERT_TABLE_EXISTS(SOURCE_SCHEMA, SOURCE_TABLE);
    -- Check the source table has a primary key
    --IF (SELECT COALESCE(KEYCOLUMNS, 0)
    --    FROM SYSCAT.TABLES
    --    WHERE TABSCHEMA = SOURCE_SCHEMA
    --    AND TABNAME = SOURCE_TABLE) = 0 THEN
    --        CALL SIGNAL_STATE(HISTORY_NO_PK_STATE, 'Source table must have a primary key');
    --END IF;
    -- Drop any existing table with the same name as the destination table
    FOR r IN
        SELECT
            'DROP TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) AS drop_cmd
        FROM
            pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n
                ON c.relnamespace = n.oid
        WHERE
            n.nspname = dest_schema
            AND c.relname = dest_table
    LOOP
        EXECUTE r.drop_cmd;
    END LOOP;
    -- Calculate comma-separated lists of key columns in the order they are
    -- declared in the primary key (for generation of constraints later)
    FOR r IN
        WITH subscripts(i) AS (
            SELECT generate_subscripts(conkey, 1)
            FROM pg_catalog.pg_constraint
            WHERE
                conrelid = CAST(
                    quote_ident(source_schema) || '.' || quote_ident(source_table)
                    AS regclass)
                AND contype = 'p'
        )
        SELECT att.attname
        FROM
            pg_catalog.pg_attribute att
            JOIN pg_catalog.pg_constraint con
                ON con.conrelid = att.attrelid
            JOIN subscripts sub
                ON att.attnum = con.conkey[sub.i]
        WHERE
            att.attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND con.contype = 'p'
            AND att.attnum > 0
        ORDER BY sub.i
    LOOP
        key_cols := key_cols
            || quote_ident(r.attname) || ',';
    END LOOP;
    -- Create the history table based on the source table
    ddl :=
        'CREATE TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' AS '
        || '('
        ||     'SELECT '
        ||          x_history_effdefault(resolution) || ' AS ' || quote_ident(x_history_effname(resolution)) || ','
        ||          x_history_expdefault(resolution) || ' AS ' || quote_ident(x_history_expname(resolution)) || ','
        ||         't.* '
        ||     'FROM '
        ||          quote_ident(source_schema) || '.' || quote_ident(source_table) || ' AS t'
        || ')'
        || 'WITH NO DATA ';
    IF dest_tbspace IS NOT NULL THEN
        ddl := ddl || 'TABLESPACE ' || quote_ident(dest_tbspace);
    END IF;
    EXECUTE ddl;
    -- Copy NOT NULL constraints from the source table to the history table
    ddl := '';
    FOR r IN
        SELECT attname
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnotnull
            AND attnum > 0
    LOOP
        ddl :=
            'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
            || ' ALTER COLUMN ' || quote_ident(r.attname) || ' SET NOT NULL';
        EXECUTE ddl;
    END LOOP;
    -- Copy CHECK and EXCLUDE constraints from the source table to the history
    -- table. Note that we do not copy FOREIGN KEY constraints as there's no
    -- good method of matching a parent record in a historized table.
    ddl := '';
    FOR r IN
        SELECT pg_get_constraintdef(oid) AS ddl
        FROM pg_catalog.pg_constraint
        WHERE
            conrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND contype IN ('c', 'x')
    LOOP
        ddl :=
            'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
            || ' ADD ' || r.ddl;
    END LOOP;
    -- Create two unique constraints, both based on the source table's primary
    -- key, plus the EFFECTIVE and EXPIRY fields respectively. Use INCLUDE for
    -- additional small fields in the EFFECTIVE index. The columns included are
    -- the same as those included in the primary key of the source table.
    -- TODO tablespaces...
    key_name := quote_ident(dest_table || '_pkey');
    ddl :=
        'CREATE UNIQUE INDEX '
        || key_name || ' '
        || 'ON ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || '(' || key_cols || quote_ident(x_history_effname(resolution))
        || ')';
    EXECUTE ddl;
    ddl :=
        'CREATE UNIQUE INDEX '
        || quote_ident(dest_table || '_ix1') || ' '
        || 'ON ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || '(' || key_cols || quote_ident(x_history_expname(resolution))
        || ')';
    EXECUTE ddl;
    -- Create additional indexes that are useful for performance purposes
    ddl :=
        'CREATE INDEX '
        || quote_ident(dest_table || '_ix2') || ' '
        || 'ON ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || '(' || quote_ident(x_history_effname(resolution))
        || ',' || quote_ident(x_history_expname(resolution))
        || ')';
    EXECUTE ddl;
    -- Create a primary key with the same fields as the EFFECTIVE index defined
    -- above.
    ddl :=
        'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || ' '
        || 'ADD PRIMARY KEY USING INDEX ' || key_name || ', '
        || 'ADD CHECK (' || quote_ident(x_history_effname(resolution)) || ' <= ' || quote_ident(x_history_expname(resolution)) || '), '
        || 'ALTER COLUMN ' || quote_ident(x_history_effname(resolution)) || ' SET DEFAULT ' || x_history_effdefault(resolution) || ', '
        || 'ALTER COLUMN ' || quote_ident(x_history_expname(resolution)) || ' SET DEFAULT ' || x_history_expdefault(resolution);
    EXECUTE ddl;
    -- TODO authorizations; needs auth.sql first
    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    ddl :=
        'COMMENT ON TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table)
        || ' IS ' || quote_literal('History table which tracks the content of @' || source_schema || '.' || source_table);
    EXECUTE ddl;
    ddl :=
        'COMMENT ON COLUMN ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '.' || quote_ident(x_history_effname(resolution))
        || ' IS ' || quote_literal('The date/timestamp from which this row was present in the source table');
    EXECUTE ddl;
    ddl :=
        'COMMENT ON COLUMN ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '.' || quote_ident(x_history_expname(resolution))
        || ' IS ' || quote_literal('The date/timestamp until which this row was present in the source table (rows with 9999-12-31 currently exist in the source table)');
    EXECUTE ddl;
    FOR r IN
        SELECT attname, COALESCE(col_description(CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass), attnum), '') AS attdesc
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 0
    LOOP
        ddl :=
            'COMMENT ON COLUMN ' || quote_ident(dest_schema) || '.' || quote_ident(dest_table) || '.' || quote_ident(r.attname)
            || ' IS ' || quote_literal(r.attdesc);
        EXECUTE ddl;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION create_history_table(
    source_table NAME,
    dest_table NAME,
    dest_tbspace NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            current_schema, source_table, current_schema, dest_table, dest_tbspace, resolution));
$$;

CREATE OR REPLACE FUNCTION create_history_table(
    source_table NAME,
    dest_table NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            source_table, dest_table, (
                SELECT spc.spcname
                FROM
                    pg_catalog.pg_class cls
                    LEFT JOIN pg_catalog.pg_tablespace spc
                        ON cls.reltablespace = spc.oid
                WHERE cls.oid = CAST(
                    quote_ident(current_schema) || '.' || quote_ident(source_table)
                    AS regclass)
            ), resolution));
$$;

CREATE OR REPLACE FUNCTION create_history_table(
    source_table NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_table(
            source_table, source_table || '_history', resolution));
$$;

GRANT EXECUTE ON FUNCTION
    create_history_table(NAME, NAME, NAME, NAME, NAME, VARCHAR),
    create_history_table(NAME, NAME, NAME, VARCHAR),
    create_history_table(NAME, NAME, VARCHAR),
    create_history_table(NAME, VARCHAR)
    TO utils_history_user;

GRANT ALL ON FUNCTION
    create_history_table(NAME, NAME, NAME, NAME, NAME, VARCHAR),
    create_history_table(NAME, NAME, NAME, VARCHAR),
    create_history_table(NAME, NAME, VARCHAR),
    create_history_table(NAME, VARCHAR)
    TO utils_history_admin WITH GRANT OPTION;

COMMENT ON FUNCTION CREATE_HISTORY_TABLE(NAME, NAME, NAME, NAME, NAME, VARCHAR)
    IS 'Creates a temporal history table based on the structure of the specified table';
COMMENT ON FUNCTION CREATE_HISTORY_TABLE(NAME, NAME, NAME, VARCHAR)
    IS 'Creates a temporal history table based on the structure of the specified table';
COMMENT ON FUNCTION CREATE_HISTORY_TABLE(NAME, NAME, VARCHAR)
    IS 'Creates a temporal history table based on the structure of the specified table';
COMMENT ON FUNCTION CREATE_HISTORY_TABLE(NAME, VARCHAR)
    IS 'Creates a temporal history table based on the structure of the specified table';

-- create_history_changes(source_schema, source_table, dest_schema, dest_view)
-- create_history_changes(source_table, dest_view)
-- create_history_changes(source_table)
-------------------------------------------------------------------------------
-- The create_history_changes procedure creates a view on top of a history
-- table which is assumed to have a structure generated by
-- create_history_table.  The view represents the history data as a series of
-- "change" rows. The "effective" and "expiry" columns from the source history
-- table are merged into a "changed" column while all other columns are
-- represented twice as an "old_" and "new_" variant.
--
-- If dest_view is not specified it defaults to the value of source_table with
-- "_history" replaced with "_changes". If dest_schema and source_schema are
-- not specified they default to the current schema.
--
-- All SELECT and CONTROL authorities present on the source table will be
-- copied to the destination table.
--
-- The type of change can be determined by querying the NULL state of the old
-- and new key columns. For example:
--
-- INSERT
-- If the old key or keys are NULL and the new are non-NULL, the change was an
-- insertion.
--
-- UPDATE
-- If both the old and new key or keys are non-NULL, the change was an update.
--
-- DELETE
-- If the old key or keys are non-NULL and the new are NULL, the change was a
-- deletion.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_history_changes(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_view NAME
)
    RETURNS VOID
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r RECORD;
BEGIN
    --CALL ASSERT_TABLE_EXISTS(SOURCE_SCHEMA, SOURCE_TABLE);
    EXECUTE
        'CREATE VIEW ' || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || ' AS '
        || x_history_changes(source_schema, source_table);
    -- Store the source table's authorizations, then redirect them to the
    -- destination table filtering out those authorizations which should be
    -- excluded
    --CALL SAVE_AUTH(SOURCE_SCHEMA, SOURCE_TABLE);
    --UPDATE SAVED_AUTH SET
    --    TABSCHEMA = DEST_SCHEMA,
    --    TABNAME = DEST_VIEW,
    --    DELETEAUTH = 'N',
    --    INSERTAUTH = 'N',
    --    UPDATEAUTH = 'N',
    --    INDEXAUTH = 'N',
    --    REFAUTH = 'N'
    --WHERE TABSCHEMA = SOURCE_SCHEMA
    --    AND TABNAME = SOURCE_TABLE;
    --CALL RESTORE_AUTH(DEST_SCHEMA, DEST_VIEW);
    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    EXECUTE
        'COMMENT ON COLUMN '
        || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || '.' || quote_ident('changed')
        || ' IS ' || quote_literal('The date/timestamp on which this row changed');
    EXECUTE
        'COMMENT ON COLUMN '
        || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || '.' || quote_ident('change')
        || ' IS ' || quote_literal('The type of change that occured (INSERT/UPDATE/DELETE)');
    EXECUTE
        'COMMENT ON VIEW '
        || quote_ident(dest_schema) || '.' || quote_ident(dest_view)
        || ' IS ' || quote_literal('View showing the content of @' || source_schema || '.' || source_table || ' as a series of changes');
    FOR r IN
        SELECT attname, COALESCE(col_description(CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass), attnum), '') AS attdesc
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 2
    LOOP
        EXECUTE
            'COMMENT ON COLUMN '
            || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || '.' || quote_ident('old_' || r.attname)
            || ' IS ' || quote_literal('Value of @' || source_schema || '.' || source_table || '.' || r.attdesc || ' prior to change');
        EXECUTE
            'COMMENT ON COLUMN '
            || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || '.' || quote_ident('new_' || r.attname)
            || ' IS ' || quote_literal('Value of @' || source_schema || '.' || source_table || '.' || r.attdesc || ' after change');
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION create_history_changes(
    source_table NAME,
    dest_view NAME
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_changes(
            current_schema, source_table, current_schema, dest_view
        ));
$$;

CREATE OR REPLACE FUNCTION create_history_changes(
    source_table NAME
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_changes(
            source_table, replace(source_table, '_history', '_changes')
        ));
$$;

GRANT EXECUTE ON FUNCTION
    create_history_changes(NAME, NAME, NAME, NAME),
    create_history_changes(NAME, NAME),
    create_history_changes(NAME)
    TO utils_history_user;

GRANT ALL ON FUNCTION
    create_history_changes(NAME, NAME, NAME, NAME),
    create_history_changes(NAME, NAME),
    create_history_changes(NAME)
    TO utils_history_admin WITH GRANT OPTION;

COMMENT ON FUNCTION create_history_changes(NAME, NAME, NAME, NAME)
    IS 'Creates an "OLD vs NEW" changes view on top of the specified history table';
COMMENT ON FUNCTION create_history_changes(NAME, NAME)
    IS 'Creates an "OLD vs NEW" changes view on top of the specified history table';
COMMENT ON FUNCTION create_history_changes(NAME)
    IS 'Creates an "OLD vs NEW" changes view on top of the specified history table';

-- create_history_snapshots(source_schema, source_table, dest_schema, dest_view, resolution)
-- create_history_snapshots(source_table, dest_view, resolution)
-- create_history_snapshots(source_table, resolution)
-------------------------------------------------------------------------------
-- The create_history_snapshots procedure creates a view on top of a history
-- table which is assumed to have a structure generated by
-- create_history_table.  The view represents the history data as a series of
-- "snapshots" of the main table at various points through time. The
-- "effective" and "expiry" columns from the source history table are replaced
-- with a "snapshot" column which indicates the timestamp or date of the
-- snapshot of the main table. All other columns are represented in their
-- original form.
--
-- If dest_view is not specified it defaults to the value of source_table with
-- "_history" replaced with a custom suffix which depends on the value of
-- resolution. For example, if resolution is 'month' then the suffix is
-- "monthly", if resolution is 'week' then the suffix is "weekly" and so on. If
-- dest_schema and source_schema are not specified they default to the current
-- schema.
--
-- The resolution parameter determines the amount of time between snapshots.
-- Snapshots will be generated for the end of each period given by a particular
-- resolution. For example, if resolution is 'week' then a snapshot will be
-- generated for the end of each week of the earliest record in the history
-- table up to the current date. See the create_history_trigger documentation
-- for a list of the possible values.
--
-- All SELECT and CONTROL authorities present on the source table will be
-- copied to the destination table.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_history_snapshots(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_view NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    ddl TEXT DEFAULT '';
    r RECORD;
BEGIN
    --CALL ASSERT_TABLE_EXISTS(SOURCE_SCHEMA, source_table);
    ddl :=
        'CREATE VIEW ' || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || ' AS '
        || x_history_snapshots(source_schema, source_table, resolution);
    EXECUTE ddl;
    -- Store the source table's authorizations, then redirect them to the
    -- destination table filtering out those authorizations which should be
    -- excluded
    --CALL SAVE_AUTH(source_schema, source_table);
    --UPDATE SAVED_AUTH SET
    --    TABSCHEMA = DEST_SCHEMA,
    --    TABNAME = dest_view,
    --    DELETEAUTH = 'N',
    --    INSERTAUTH = 'N',
    --    UPDATEAUTH = 'N',
    --    INDEXAUTH = 'N',
    --    REFAUTH = 'N'
    --WHERE TABSCHEMA = source_schema
    --    AND TABNAME = source_table;
    --CALL RESTORE_AUTH(DEST_SCHEMA, dest_view);
    -- Set up comments for the effective and expiry fields then copy the
    -- comments for all fields from the source table
    ddl := 'COMMENT ON COLUMN '
        || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || '.' || quote_ident('snapshot')
        || ' IS ' || quote_literal('The date/timestamp of this row''s snapshot');
    EXECUTE ddl;
    ddl := 'COMMENT ON VIEW '
        || quote_ident(dest_schema) || '.' || quote_ident(dest_view)
        || ' IS ' || quote_literal('View showing the content of @' || source_schema || '.' || source_table || ' as a series of snapshots');
    EXECUTE ddl;
    FOR r IN
        SELECT attname, COALESCE(col_description(CAST(
            quote_ident(source_schema) || '.' || quote_ident(source_table)
            AS regclass), attnum), '') AS attdesc
        FROM pg_catalog.pg_attribute
        WHERE
            attrelid = CAST(
                quote_ident(source_schema) || '.' || quote_ident(source_table)
                AS regclass)
            AND attnum > 2
    LOOP
        ddl := 'COMMENT ON COLUMN '
            || quote_ident(dest_schema) || '.' || quote_ident(dest_view) || '.' || quote_ident(r.attname)
            || ' IS ' || quote_literal('Value of @' || source_schema || '.' || source_table || '.' || r.attdesc || ' prior to change');
        EXECUTE ddl;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION create_history_snapshots(
    source_table NAME,
    dest_view NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_snapshots(
            current_schema, source_table, current_schema, dest_view, resolution
    ));
$$;

CREATE OR REPLACE FUNCTION create_history_snapshots(
    source_table NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_snapshots(
            source_table, replace(source_table, '_history', '_by_' || resolution), resolution
        ));
$$;

GRANT EXECUTE ON FUNCTION
    create_history_snapshots(NAME, NAME, NAME, NAME, VARCHAR),
    create_history_snapshots(NAME, NAME, VARCHAR),
    create_history_snapshots(NAME, VARCHAR)
    TO utils_history_user;

GRANT EXECUTE ON FUNCTION
    create_history_snapshots(NAME, NAME, NAME, NAME, VARCHAR),
    create_history_snapshots(NAME, NAME, VARCHAR),
    create_history_snapshots(NAME, VARCHAR)
    TO utils_history_admin WITH GRANT OPTION;

COMMENT ON FUNCTION create_history_snapshots(NAME, NAME, NAME, NAME, VARCHAR)
    IS 'Creates an exploded view of the specified history table with one row per entity per resolution time-slice (e.g. daily, monthly, yearly, etc.)';
COMMENT ON FUNCTION create_history_snapshots(NAME, NAME, VARCHAR)
    IS 'Creates an exploded view of the specified history table with one row per entity per resolution time-slice (e.g. daily, monthly, yearly, etc.)';
COMMENT ON FUNCTION create_history_snapshots(NAME, VARCHAR)
    IS 'Creates an exploded view of the specified history table with one row per entity per resolution time-slice (e.g. daily, monthly, yearly, etc.)';

-- create_history_triggers(source_schema, source_table, dest_schema, dest_table, resolution, offset)
-- create_history_triggers(source_table, dest_table, resolution, offset)
-- create_history_triggers(source_table, resolution, offset)
-- create_history_triggers(source_table, resolution)
-------------------------------------------------------------------------------
-- The create_history_triggers procedure creates several trigger linking the
-- specified source table to the destination table which is assumed to have a
-- structure compatible with the result of running create_history_table above,
-- i.e. two extra columns called effective_date and expiry_date.
--
-- If dest_table is not specified it defaults to the value of source_table with
-- "_history" as a suffix. If dest_schema and source_schema are not specified
-- they default to the current schema.
--
-- The resolution parameter specifies the smallest unit of time that a history
-- entry can cover. This is effectively used to quantize the history. The value
-- given for the resolution parameter should match the value given as the
-- resolution parameter to the create_history_table procedure. The values
-- which can be specified are the same as the field parameter of the date_trunc
-- function.
--
-- The shift parameter specifies an SQL interval that will be used to offset
-- the effective dates of new history records. For example, if the source table
-- is only updated a week in arrears, then offset could be set to "- INTERVAL
-- '7 DAYS'" to cause the effective dates to be accurate.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION create_history_triggers(
    source_schema NAME,
    source_table NAME,
    dest_schema NAME,
    dest_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS VOID
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    r RECORD;
BEGIN
    --CALL ASSERT_TABLE_EXISTS(SOURCE_SCHEMA, SOURCE_TABLE);
    --CALL ASSERT_TABLE_EXISTS(DEST_SCHEMA, DEST_TABLE);
    -- Drop any existing triggers with the same name as the destination
    -- triggers in case there are any left over
    FOR r IN
        SELECT
            'DROP TRIGGER ' || quote_ident(tgname) || ' ON ' || CAST(tgrelid AS regclass) AS drop_trig
        FROM
            pg_catalog.pg_trigger
        WHERE
            tgrelid = CAST(quote_ident(source_schema) || '.' || quote_ident(source_table) AS regclass)
            AND tgname IN (
                source_table || '_keychg',
                source_table || '_insert',
                source_table || '_update',
                source_table || '_delete'
            )
    LOOP
        EXECUTE r.drop_trig;
    END LOOP;
    -- Drop any existing functions with the same name as the destination
    -- trigger functions
    FOR r IN
        SELECT
            'DROP FUNCTION ' || CAST(p.oid AS regprocedure) || ' CASCADE' AS drop_func
        FROM
            pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n
                ON p.pronamespace = n.oid
        WHERE
            n.nspname = source_schema
            AND p.pronargs = 0
            AND p.prorettype = CAST('trigger' AS regtype)
            AND p.proname IN (
                source_table || '_keychg',
                source_table || '_insert',
                source_table || '_update',
                source_table || '_delete'
            )
    LOOP
        EXECUTE r.drop_func;
    END LOOP;
    -- Create the KEYCHG trigger
    EXECUTE
        'CREATE FUNCTION ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_keychg') || '() '
        ||     'RETURNS trigger '
        ||     'LANGUAGE plpgsql '
        ||     'IMMUTABLE '
        || 'AS $func$ '
        || 'BEGIN '
        ||     'RAISE EXCEPTION USING '
        ||         'MESSAGE = ' || quote_literal('Cannot update unique key of a row in ' || source_schema || '.' || source_table) || ';'
        ||     'RETURN NULL; '
        || 'END; '
        || '$func$';
    EXECUTE
        'CREATE TRIGGER ' || quote_ident(source_table || '_keychg') || ' '
        ||     'BEFORE UPDATE OF ' || x_history_update_fields(source_schema, source_table, true) || ' '
        ||     'ON ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' '
        ||     'FOR EACH ROW '
        ||     'WHEN (' || x_history_update_when(source_schema, source_table, true) || ') '
        ||     'EXECUTE PROCEDURE ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_keychg') || '()';
    -- Create the INSERT trigger
    EXECUTE
        'CREATE FUNCTION ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_insert') || '() '
        ||     'RETURNS trigger '
        ||     'LANGUAGE plpgsql '
        ||     'VOLATILE '
        || 'AS $func$ '
        || 'BEGIN '
        ||      x_history_insert(source_schema, source_table, dest_schema, dest_table, resolution, shift) || '; '
        ||     'RETURN NEW;'
        || 'END; '
        || '$func$';
    EXECUTE
        'CREATE TRIGGER ' || quote_ident(source_table || '_insert') || ' '
        ||     'AFTER INSERT ON ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' '
        ||     'FOR EACH ROW '
        ||     'EXECUTE PROCEDURE ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_insert') || '()';
    -- Create the UPDATE trigger
    EXECUTE
        'CREATE FUNCTION ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_update') || '()'
        ||     'RETURNS trigger '
        ||     'LANGUAGE plpgsql '
        ||     'VOLATILE '
        || 'AS $func$ '
        || 'DECLARE '
        ||     'chk_date TIMESTAMP; '
        || 'BEGIN '
        ||     'chk_date := ('
        ||         x_history_check(source_schema, source_table, dest_schema, dest_table, resolution)
        ||     '); '
        ||     'IF ' || x_history_effnext(resolution, shift) || ' > chk_date THEN '
        ||         x_history_expire(source_schema, source_table, dest_schema, dest_table, resolution, shift) || '; '
        ||         x_history_insert(source_schema, source_table, dest_schema, dest_table, resolution, shift) || '; '
        ||     'ELSE '
        ||         x_history_update(source_schema, source_table, dest_schema, dest_table, resolution) || '; '
        ||     'END IF; '
        ||     'RETURN NEW; '
        || 'END; '
        || '$func$';
    EXECUTE
        'CREATE TRIGGER ' || quote_ident(source_table || '_update') || ' '
        ||     'AFTER UPDATE OF ' || x_history_update_fields(source_schema, source_table, false) || ' '
        ||     'ON ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' '
        ||     'FOR EACH ROW '
        ||     'WHEN (' || x_history_update_when(source_schema, source_table, false) || ') '
        ||     'EXECUTE PROCEDURE ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_update') || '()';
    -- Create the DELETE trigger
    EXECUTE
        'CREATE FUNCTION ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_delete') || '()'
        ||     'RETURNS trigger '
        ||     'LANGUAGE plpgsql '
        ||     'VOLATILE '
        || 'AS $func$ '
        || 'DECLARE '
        ||     'chk_date TIMESTAMP; '
        || 'BEGIN '
        ||     'chk_date := ('
        ||         x_history_check(source_schema, source_table, dest_schema, dest_table, resolution)
        ||     '); '
        ||     'IF ' || x_history_effnext(resolution, shift) || ' > chk_date THEN '
        ||         x_history_expire(source_schema, source_table, dest_schema, dest_table, resolution, shift) || '; '
        ||     'ELSE '
        ||         x_history_delete(source_schema, source_table, dest_schema, dest_table, resolution) || '; '
        ||     'END IF; '
        ||     'RETURN OLD; '
        || 'END; '
        || '$func$';
    EXECUTE
        'CREATE TRIGGER ' || quote_ident(source_table || '_delete') || ' '
        ||     'AFTER DELETE ON ' || quote_ident(source_schema) || '.' || quote_ident(source_table) || ' '
        ||     'FOR EACH ROW '
        ||     'EXECUTE PROCEDURE ' || quote_ident(source_schema) || '.' || quote_ident(source_table || '_delete') || '()';
END;
$$;

CREATE OR REPLACE FUNCTION create_history_triggers(
    source_table NAME,
    dest_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_triggers(
            current_schema, source_table, current_schema, dest_table, resolution, shift
        ));
$$;

CREATE OR REPLACE FUNCTION create_history_triggers(
    source_table NAME,
    resolution VARCHAR(12),
    shift INTERVAL
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_triggers(
            source_table, source_table || '_history', resolution, shift
        ));
$$;

CREATE OR REPLACE FUNCTION create_history_triggers(
    source_table NAME,
    resolution VARCHAR(12)
)
    RETURNS VOID
    LANGUAGE SQL
    VOLATILE
AS $$
    VALUES (
        create_history_triggers(
            source_table, source_table || '_history', resolution, interval '0 microseconds'
        ));
$$;

GRANT EXECUTE ON FUNCTION
    create_history_triggers(NAME, NAME, NAME, NAME, VARCHAR, INTERVAL),
    create_history_triggers(NAME, NAME, VARCHAR, INTERVAL),
    create_history_triggers(NAME, VARCHAR, INTERVAL),
    create_history_triggers(NAME, VARCHAR)
    TO utils_history_user;

GRANT EXECUTE ON FUNCTION
    create_history_triggers(NAME, NAME, NAME, NAME, VARCHAR, INTERVAL),
    create_history_triggers(NAME, NAME, VARCHAR, INTERVAL),
    create_history_triggers(NAME, VARCHAR, INTERVAL),
    create_history_triggers(NAME, VARCHAR)
    TO utils_history_admin WITH GRANT OPTION;

COMMENT ON FUNCTION create_history_triggers(NAME, NAME, NAME, NAME, VARCHAR, INTERVAL)
    IS 'Creates the triggers to link the specified table to its corresponding history table';
COMMENT ON FUNCTION create_history_triggers(NAME, NAME, VARCHAR, INTERVAL)
    IS 'Creates the triggers to link the specified table to its corresponding history table';
COMMENT ON FUNCTION create_history_triggers(NAME, VARCHAR, INTERVAL)
    IS 'Creates the triggers to link the specified table to its corresponding history table';
COMMENT ON FUNCTION create_history_triggers(NAME, VARCHAR)
    IS 'Creates the triggers to link the specified table to its corresponding history table';

-- vim: set et sw=4 sts=4:
