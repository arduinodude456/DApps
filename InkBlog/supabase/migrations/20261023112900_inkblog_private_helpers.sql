BEGIN;

-- Keep security-definer internals outside the exposed PostgREST public schema.
CREATE SCHEMA inkblog_private;
REVOKE ALL ON SCHEMA inkblog_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA inkblog_private TO anon, authenticated, service_role;

ALTER FUNCTION public.inkblog_is_blocked_between(uuid, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_owns_post(uuid, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_can_read_post(uuid, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_can_interact_with_post(uuid, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_can_read_target(text, uuid, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_can_interact_with_target(text, uuid, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_can_read_avatar_path(text, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_can_read_post_image_path(text, uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_email_confirmed(uuid) SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_validate_profile_avatar() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_validate_post_image() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_set_post_timestamps() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_validate_comment() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_validate_polymorphic_target() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_validate_notification() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_notify_follow() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_notify_like() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_notify_comment() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_cleanup_deleted_post_targets() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_cleanup_deleted_comment_targets() SET SCHEMA inkblog_private;
ALTER FUNCTION public.inkblog_cleanup_block_relationships() SET SCHEMA inkblog_private;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_is_blocked_between(p_left uuid, p_right uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT p_left IS NOT NULL
       AND p_right IS NOT NULL
       AND EXISTS (
            SELECT 1
            FROM public.inkblog_blocks AS b
            WHERE (b.blocker_id = p_left AND b.blocked_id = p_right)
               OR (b.blocker_id = p_right AND b.blocked_id = p_left)
       );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_owns_post(p_post_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT p_user_id IS NOT NULL
       AND EXISTS (
            SELECT 1 FROM public.inkblog_posts AS p
            WHERE p.id = p_post_id AND p.author_id = p_user_id
       );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_can_read_post(p_post_id uuid, p_viewer_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.inkblog_posts AS p
        WHERE p.id = p_post_id
          AND (p.status = 'published' OR p.author_id = p_viewer_id)
          AND NOT inkblog_private.inkblog_is_blocked_between(p.author_id, p_viewer_id)
    );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_can_interact_with_post(p_post_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT p_user_id IS NOT NULL
       AND EXISTS (
            SELECT 1
            FROM public.inkblog_posts AS p
            WHERE p.id = p_post_id
              AND (p.status = 'published' OR p.author_id = p_user_id)
              AND NOT inkblog_private.inkblog_is_blocked_between(p.author_id, p_user_id)
       );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_can_read_target(
    p_target_type text,
    p_target_id uuid,
    p_viewer_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_post_author uuid;
    v_comment_author uuid;
    v_published boolean;
BEGIN
    IF p_target_type = 'post' THEN
        RETURN inkblog_private.inkblog_can_read_post(p_target_id, p_viewer_id);
    ELSIF p_target_type = 'comment' THEN
        SELECT p.author_id, c.author_id, p.status = 'published'
          INTO v_post_author, v_comment_author, v_published
          FROM public.inkblog_comments AS c
          JOIN public.inkblog_posts AS p ON p.id = c.post_id
         WHERE c.id = p_target_id;
        RETURN FOUND
           AND (p_viewer_id = v_post_author OR v_published)
           AND NOT inkblog_private.inkblog_is_blocked_between(v_post_author, p_viewer_id)
           AND NOT inkblog_private.inkblog_is_blocked_between(v_comment_author, p_viewer_id);
    END IF;
    RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_can_interact_with_target(
    p_target_type text,
    p_target_id uuid,
    p_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_post_author uuid;
    v_comment_author uuid;
    v_published boolean;
BEGIN
    IF p_user_id IS NULL THEN
        RETURN false;
    ELSIF p_target_type = 'post' THEN
        SELECT p.author_id, p.status = 'published'
          INTO v_post_author, v_published
          FROM public.inkblog_posts AS p
         WHERE p.id = p_target_id;
        RETURN FOUND
           AND v_published
           AND NOT inkblog_private.inkblog_is_blocked_between(v_post_author, p_user_id);
    ELSIF p_target_type = 'comment' THEN
        SELECT p.author_id, c.author_id, p.status = 'published'
          INTO v_post_author, v_comment_author, v_published
          FROM public.inkblog_comments AS c
          JOIN public.inkblog_posts AS p ON p.id = c.post_id
         WHERE c.id = p_target_id;
        RETURN FOUND
           AND v_published
           AND NOT inkblog_private.inkblog_is_blocked_between(v_post_author, p_user_id)
           AND NOT inkblog_private.inkblog_is_blocked_between(v_comment_author, p_user_id);
    END IF;
    RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_can_read_avatar_path(p_path text, p_viewer_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.inkblog_profiles AS pr
        WHERE pr.avatar_path = p_path
          AND NOT inkblog_private.inkblog_is_blocked_between(pr.id, p_viewer_id)
    );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_can_read_post_image_path(p_path text, p_viewer_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.inkblog_post_images AS i
        WHERE i.path = p_path
          AND inkblog_private.inkblog_can_read_post(i.post_id, p_viewer_id)
    );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_email_confirmed(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT p_user_id IS NOT NULL
       AND EXISTS (
            SELECT 1
            FROM auth.users AS u
            WHERE u.id = p_user_id
              AND u.email_confirmed_at IS NOT NULL
       );
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_validate_profile_avatar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_metadata jsonb;
BEGIN
    IF NEW.avatar_path IS NULL THEN
        RETURN NEW;
    END IF;

    -- Edge processing owns the only legal object shape:
    -- <user uuid>/<processed image uuid>.png, max 128 x 128.
    IF NEW.avatar_path !~ ('^' || NEW.id::text || '/[0-9a-fA-F-]{36}\.png$') THEN
        RAISE EXCEPTION 'InkBlog avatar path is not a processed avatar path'
            USING ERRCODE = '23514';
    END IF;

    SELECT coalesce(o.metadata, '{}'::jsonb) || coalesce(o.user_metadata, '{}'::jsonb) INTO v_metadata
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-avatars'
       AND o.name = NEW.avatar_path;

    IF NOT FOUND
       OR coalesce(v_metadata->>'mimetype', v_metadata->>'contentType') <> 'image/png'
       OR coalesce(v_metadata->>'width', '') !~ '^[0-9]+$'
       OR coalesce(v_metadata->>'height', '') !~ '^[0-9]+$'
       OR (v_metadata->>'width')::integer NOT BETWEEN 1 AND 128
       OR (v_metadata->>'height')::integer NOT BETWEEN 1 AND 128 THEN
        RAISE EXCEPTION 'InkBlog avatar must reference an existing server-processed PNG no larger than 128x128'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_validate_post_image()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_post_author uuid;
    v_metadata jsonb;
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.author_id IS DISTINCT FROM OLD.author_id
        OR NEW.post_id IS DISTINCT FROM OLD.post_id
        OR NEW.path IS DISTINCT FROM OLD.path
    ) THEN
        RAISE EXCEPTION 'image ownership, post, and processed path are immutable'
            USING ERRCODE = '42501';
    END IF;

    SELECT p.author_id INTO v_post_author
      FROM public.inkblog_posts AS p
     WHERE p.id = NEW.post_id;

    IF NOT FOUND OR v_post_author <> NEW.author_id THEN
        RAISE EXCEPTION 'post image author must own its post' USING ERRCODE = '23514';
    END IF;

    -- Edge processing owns the only legal object shape:
    -- <user uuid>/<post uuid>/<processed image uuid>.png, max 800 x 1000.
    IF NEW.path !~ ('^' || NEW.author_id::text || '/' || NEW.post_id::text || '/[0-9a-fA-F-]{36}\.png$') THEN
        RAISE EXCEPTION 'InkBlog image path is not a processed post-image path'
            USING ERRCODE = '23514';
    END IF;

    SELECT coalesce(o.metadata, '{}'::jsonb) || coalesce(o.user_metadata, '{}'::jsonb) INTO v_metadata
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-images'
       AND o.name = NEW.path;

    IF NOT FOUND
       OR coalesce(v_metadata->>'mimetype', v_metadata->>'contentType') <> 'image/png'
       OR coalesce(v_metadata->>'width', '') !~ '^[0-9]+$'
       OR coalesce(v_metadata->>'height', '') !~ '^[0-9]+$'
       OR (v_metadata->>'width')::integer NOT BETWEEN 1 AND 800
       OR (v_metadata->>'height')::integer NOT BETWEEN 1 AND 1000
       OR NEW.width IS DISTINCT FROM (v_metadata->>'width')::integer
       OR NEW.height IS DISTINCT FROM (v_metadata->>'height')::integer THEN
        RAISE EXCEPTION 'InkBlog image must reference an existing server-processed PNG with matching dimensions'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_set_post_timestamps()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_now timestamptz := clock_timestamp();
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := v_now;
        NEW.updated_at := v_now;
        IF NEW.status = 'published' THEN
            NEW.published_at := v_now;
        ELSE
            NEW.published_at := NULL;
        END IF;
    ELSE
        IF NEW.author_id IS DISTINCT FROM OLD.author_id
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'post ownership and creation time are immutable'
                USING ERRCODE = '42501';
        END IF;
        NEW.updated_at := v_now;
        IF NEW.status = 'published' AND OLD.status = 'draft' THEN
            NEW.published_at := v_now;
        ELSIF NEW.status = 'draft' THEN
            NEW.published_at := NULL;
        ELSE
            NEW.published_at := OLD.published_at;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_validate_comment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_parent_post uuid;
    v_parent_parent uuid;
    v_parent_author uuid;
BEGIN
    IF TG_OP = 'UPDATE' AND (
        NEW.author_id IS DISTINCT FROM OLD.author_id
        OR NEW.post_id IS DISTINCT FROM OLD.post_id
        OR NEW.parent_id IS DISTINCT FROM OLD.parent_id
        OR NEW.created_at IS DISTINCT FROM OLD.created_at
    ) THEN
        RAISE EXCEPTION 'comment ownership, parent, post, and creation time are immutable'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.parent_id IS NOT NULL THEN
        SELECT c.post_id, c.parent_id, c.author_id
          INTO v_parent_post, v_parent_parent, v_parent_author
          FROM public.inkblog_comments AS c
         WHERE c.id = NEW.parent_id;

        IF NOT FOUND OR v_parent_post <> NEW.post_id OR v_parent_parent IS NOT NULL THEN
            RAISE EXCEPTION 'a reply must target a top-level comment on the same post'
                USING ERRCODE = '23514';
        END IF;
        IF inkblog_private.inkblog_is_blocked_between(NEW.author_id, v_parent_author) THEN
            RAISE EXCEPTION 'blocked users cannot reply to one another'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_validate_polymorphic_target()
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

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_validate_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_exists boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.recipient_id IS DISTINCT FROM OLD.recipient_id
           OR NEW.actor_id IS DISTINCT FROM OLD.actor_id
           OR NEW.kind IS DISTINCT FROM OLD.kind
           OR NEW.target_type IS DISTINCT FROM OLD.target_type
           OR NEW.target_id IS DISTINCT FROM OLD.target_id
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'only notification read_at may be changed'
                USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.kind = 'follow' THEN
        v_exists := NEW.target_type = 'user'
                    AND NEW.target_id = NEW.actor_id
                    AND EXISTS (SELECT 1 FROM auth.users WHERE id = NEW.target_id);
    ELSIF NEW.kind = 'like' THEN
        v_exists := NEW.target_type IN ('post', 'comment')
                    AND inkblog_private.inkblog_can_read_target(NEW.target_type, NEW.target_id, NEW.recipient_id);
    ELSE
        v_exists := NEW.target_type = 'comment'
                    AND EXISTS (SELECT 1 FROM public.inkblog_comments WHERE id = NEW.target_id);
    END IF;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'notification target is invalid' USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_notify_follow()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NOT inkblog_private.inkblog_is_blocked_between(NEW.follower_id, NEW.following_id) THEN
        INSERT INTO public.inkblog_notifications
            (recipient_id, actor_id, kind, target_type, target_id)
        VALUES
            (NEW.following_id, NEW.follower_id, 'follow', 'user', NEW.follower_id);
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_notify_like()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_recipient uuid;
BEGIN
    IF NEW.target_type = 'post' THEN
        SELECT p.author_id INTO v_recipient
          FROM public.inkblog_posts AS p WHERE p.id = NEW.target_id;
    ELSE
        SELECT c.author_id INTO v_recipient
          FROM public.inkblog_comments AS c WHERE c.id = NEW.target_id;
    END IF;

    IF v_recipient IS NOT NULL
       AND v_recipient <> NEW.user_id
       AND NOT inkblog_private.inkblog_is_blocked_between(v_recipient, NEW.user_id) THEN
        INSERT INTO public.inkblog_notifications
            (recipient_id, actor_id, kind, target_type, target_id)
        VALUES
            (v_recipient, NEW.user_id, 'like', NEW.target_type, NEW.target_id);
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_notify_comment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_post_author uuid;
    v_parent_author uuid;
BEGIN
    SELECT p.author_id INTO v_post_author
      FROM public.inkblog_posts AS p WHERE p.id = NEW.post_id;

    IF v_post_author IS NOT NULL
       AND v_post_author <> NEW.author_id
       AND NOT inkblog_private.inkblog_is_blocked_between(v_post_author, NEW.author_id) THEN
        INSERT INTO public.inkblog_notifications
            (recipient_id, actor_id, kind, target_type, target_id)
        VALUES
            (v_post_author, NEW.author_id, 'comment', 'comment', NEW.id);
    END IF;

    IF NEW.parent_id IS NOT NULL THEN
        SELECT c.author_id INTO v_parent_author
          FROM public.inkblog_comments AS c WHERE c.id = NEW.parent_id;
        IF v_parent_author IS NOT NULL
           AND v_parent_author <> NEW.author_id
           AND v_parent_author <> v_post_author
           AND NOT inkblog_private.inkblog_is_blocked_between(v_parent_author, NEW.author_id) THEN
            INSERT INTO public.inkblog_notifications
                (recipient_id, actor_id, kind, target_type, target_id)
            VALUES
                (v_parent_author, NEW.author_id, 'reply', 'comment', NEW.id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_cleanup_deleted_post_targets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    DELETE FROM public.inkblog_likes
     WHERE target_type = 'post' AND target_id = OLD.id;
    DELETE FROM public.inkblog_reports
     WHERE target_type = 'post' AND target_id = OLD.id;
    DELETE FROM public.inkblog_notifications
     WHERE target_type = 'post' AND target_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_cleanup_deleted_comment_targets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    DELETE FROM public.inkblog_likes
     WHERE target_type = 'comment' AND target_id = OLD.id;
    DELETE FROM public.inkblog_reports
     WHERE target_type = 'comment' AND target_id = OLD.id;
    DELETE FROM public.inkblog_notifications
     WHERE target_type = 'comment' AND target_id = OLD.id;
    RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION inkblog_private.inkblog_cleanup_block_relationships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    DELETE FROM public.inkblog_follows AS f
     WHERE (f.follower_id = NEW.blocker_id AND f.following_id = NEW.blocked_id)
        OR (f.follower_id = NEW.blocked_id AND f.following_id = NEW.blocker_id);

    -- Old reactions and notifications between the pair are removed;
    -- reports are retained: blocking must never erase a moderation complaint.
    -- the remaining content is hidden in both directions by the RLS helpers.
    DELETE FROM public.inkblog_likes AS l
    USING public.inkblog_posts AS p
     WHERE l.target_type = 'post'
       AND l.target_id = p.id
       AND ((l.user_id = NEW.blocker_id AND p.author_id = NEW.blocked_id)
         OR (l.user_id = NEW.blocked_id AND p.author_id = NEW.blocker_id));
    DELETE FROM public.inkblog_likes AS l
    USING public.inkblog_comments AS c
     WHERE l.target_type = 'comment'
       AND l.target_id = c.id
       AND ((l.user_id = NEW.blocker_id AND c.author_id = NEW.blocked_id)
         OR (l.user_id = NEW.blocked_id AND c.author_id = NEW.blocker_id));
    DELETE FROM public.inkblog_notifications AS n
     WHERE (n.recipient_id = NEW.blocker_id AND n.actor_id = NEW.blocked_id)
        OR (n.recipient_id = NEW.blocked_id AND n.actor_id = NEW.blocker_id);
    RETURN NEW;
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA inkblog_private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_is_blocked_between(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_owns_post(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_can_read_post(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_can_interact_with_post(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_can_read_target(text, uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_can_interact_with_target(text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_can_read_avatar_path(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_can_read_post_image_path(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION inkblog_private.inkblog_email_confirmed(uuid) TO authenticated;

COMMIT;
