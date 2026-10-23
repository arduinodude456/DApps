-- Evaluate auth claims once per statement rather than once per candidate row.
-- Rebuild only InkBlog RLS policies; all existing DChat policies are untouched.
DO $inkblog_policy_optimize$
DECLARE
    policy_row record;
    role_list text;
    using_expr text;
    check_expr text;
    statement text;
BEGIN
    FOR policy_row IN
        SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
        FROM pg_catalog.pg_policies
        WHERE schemaname = 'public'
          AND tablename LIKE 'inkblog\_%' ESCAPE '\'
          AND policyname LIKE 'inkblog\_%' ESCAPE '\'
          AND (coalesce(qual, '') || coalesce(with_check, '')) ~* 'auth\.[a-z_]+[[:space:]]*\('
    LOOP
        SELECT string_agg(
            CASE WHEN role_name = 'public' THEN 'PUBLIC' ELSE format('%I', role_name) END,
            ', '
        )
        INTO role_list
        FROM unnest(policy_row.roles) AS role_name;

        using_expr := CASE WHEN policy_row.qual IS NULL THEN NULL ELSE
            regexp_replace(policy_row.qual, 'auth\.uid\(\)', '(select auth.uid())', 'gi') END;
        check_expr := CASE WHEN policy_row.with_check IS NULL THEN NULL ELSE
            regexp_replace(policy_row.with_check, 'auth\.uid\(\)', '(select auth.uid())', 'gi') END;

        EXECUTE format('DROP POLICY %I ON %I.%I', policy_row.policyname, policy_row.schemaname, policy_row.tablename);
        statement := format('CREATE POLICY %I ON %I.%I AS %s FOR %s TO %s',
            policy_row.policyname, policy_row.schemaname, policy_row.tablename,
            policy_row.permissive, policy_row.cmd, role_list);
        IF using_expr IS NOT NULL THEN statement := statement || format(' USING (%s)', using_expr); END IF;
        IF check_expr IS NOT NULL THEN statement := statement || format(' WITH CHECK (%s)', check_expr); END IF;
        EXECUTE statement;
    END LOOP;
END
$inkblog_policy_optimize$;
