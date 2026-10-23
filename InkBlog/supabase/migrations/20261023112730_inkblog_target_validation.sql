BEGIN;

-- A polymorphic trigger must never dereference fields that exist on only one of
-- its two tables. The first live Like test exposed the old generic UPDATE check.
CREATE OR REPLACE FUNCTION public.inkblog_validate_polymorphic_target()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_exists boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'likes and reports are immutable; delete and create instead'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.target_type = 'post' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.inkblog_posts AS p WHERE p.id = NEW.target_id LIMIT 1
        ) INTO v_exists;
    ELSIF NEW.target_type = 'comment' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.inkblog_comments AS c WHERE c.id = NEW.target_id LIMIT 1
        ) INTO v_exists;
    ELSE
        v_exists := false;
    END IF;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'InkBlog target does not exist' USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.inkblog_validate_polymorphic_target() FROM PUBLIC;

COMMIT;
