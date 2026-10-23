BEGIN;

-- InkBlog is deliberately namespaced by object name rather than a new schema so
-- PostgREST can expose the RPCs and tables through the existing public schema.

CREATE TABLE public.inkblog_profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name text NOT NULL,
    bio text NOT NULL DEFAULT '',
    avatar_path text UNIQUE,
    CONSTRAINT inkblog_profiles_display_name_check
        CHECK (char_length(display_name) BETWEEN 1 AND 80 AND display_name = btrim(display_name)),
    CONSTRAINT inkblog_profiles_bio_check CHECK (char_length(bio) <= 2_000),
    CONSTRAINT inkblog_profiles_avatar_path_check
        CHECK (avatar_path IS NULL OR (char_length(avatar_path) BETWEEN 5 AND 1_024))
);

CREATE TABLE public.inkblog_posts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title text NOT NULL,
    markdown text NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    published_at timestamptz,
    CONSTRAINT inkblog_posts_title_check
        CHECK (char_length(title) BETWEEN 1 AND 240 AND title = btrim(title)),
    CONSTRAINT inkblog_posts_markdown_check CHECK (char_length(markdown) <= 100_000),
    CONSTRAINT inkblog_posts_status_check CHECK (status IN ('draft', 'published')),
    CONSTRAINT inkblog_posts_published_at_check
        CHECK ((status = 'draft' AND published_at IS NULL) OR (status = 'published' AND published_at IS NOT NULL))
);

CREATE TABLE public.inkblog_post_images (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id uuid NOT NULL REFERENCES public.inkblog_posts(id) ON DELETE CASCADE,
    author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    path text NOT NULL UNIQUE,
    alt_text text NOT NULL DEFAULT '',
    width integer NOT NULL,
    height integer NOT NULL,
    CONSTRAINT inkblog_post_images_path_check
        CHECK (char_length(path) BETWEEN 5 AND 1_024 AND lower(right(path, 4)) = '.png'),
    CONSTRAINT inkblog_post_images_alt_text_check CHECK (char_length(alt_text) <= 500),
    CONSTRAINT inkblog_post_images_width_check CHECK (width BETWEEN 1 AND 800),
    CONSTRAINT inkblog_post_images_height_check CHECK (height BETWEEN 1 AND 1_000)
);

CREATE TABLE public.inkblog_follows (
    follower_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    following_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (follower_id, following_id),
    CONSTRAINT inkblog_follows_not_self_check CHECK (follower_id <> following_id)
);

CREATE TABLE public.inkblog_likes (
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id, target_type, target_id),
    CONSTRAINT inkblog_likes_target_type_check CHECK (target_type IN ('post', 'comment'))
);

CREATE TABLE public.inkblog_comments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id uuid NOT NULL REFERENCES public.inkblog_posts(id) ON DELETE CASCADE,
    author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    parent_id uuid REFERENCES public.inkblog_comments(id) ON DELETE CASCADE,
    body text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT inkblog_comments_body_check
        CHECK (char_length(body) BETWEEN 1 AND 10_000 AND body = btrim(body)),
    CONSTRAINT inkblog_comments_not_own_parent_check CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE TABLE public.inkblog_notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    kind text NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    read_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT inkblog_notifications_not_self_check CHECK (recipient_id <> actor_id),
    CONSTRAINT inkblog_notifications_kind_check CHECK (kind IN ('follow', 'like', 'comment', 'reply')),
    CONSTRAINT inkblog_notifications_target_type_check CHECK (target_type IN ('post', 'comment', 'user'))
);

CREATE TABLE public.inkblog_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    reason text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT inkblog_reports_target_type_check CHECK (target_type IN ('post', 'comment')),
    CONSTRAINT inkblog_reports_reason_check
        CHECK (char_length(reason) BETWEEN 1 AND 2_000 AND reason = btrim(reason))
);

CREATE TABLE public.inkblog_blocks (
    blocker_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    blocked_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (blocker_id, blocked_id),
    CONSTRAINT inkblog_blocks_not_self_check CHECK (blocker_id <> blocked_id)
);

CREATE INDEX inkblog_posts_feed_idx
    ON public.inkblog_posts (status, published_at DESC, id DESC);
CREATE INDEX inkblog_posts_author_idx
    ON public.inkblog_posts (author_id, created_at DESC, id DESC);
CREATE INDEX inkblog_post_images_post_idx
    ON public.inkblog_post_images (post_id, id);
CREATE INDEX inkblog_follows_following_idx
    ON public.inkblog_follows (following_id, follower_id);
CREATE INDEX inkblog_likes_target_idx
    ON public.inkblog_likes (target_type, target_id, created_at DESC);
CREATE INDEX inkblog_comments_post_idx
    ON public.inkblog_comments (post_id, created_at, id);
CREATE INDEX inkblog_comments_parent_idx
    ON public.inkblog_comments (parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX inkblog_notifications_recipient_idx
    ON public.inkblog_notifications (recipient_id, read_at, created_at DESC, id DESC);
CREATE INDEX inkblog_reports_target_idx
    ON public.inkblog_reports (target_type, target_id, created_at DESC);
CREATE INDEX inkblog_blocks_blocked_idx
    ON public.inkblog_blocks (blocked_id, blocker_id);

-- Security-definer helpers have a fixed path, no dynamic SQL, and narrowly
-- granted EXECUTE. They read through RLS boundaries without making a view a
-- bypass mechanism.
CREATE FUNCTION public.inkblog_is_blocked_between(p_left uuid, p_right uuid)
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

CREATE FUNCTION public.inkblog_owns_post(p_post_id uuid, p_user_id uuid)
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

CREATE FUNCTION public.inkblog_can_read_post(p_post_id uuid, p_viewer_id uuid)
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
          AND NOT public.inkblog_is_blocked_between(p.author_id, p_viewer_id)
    );
$$;

CREATE FUNCTION public.inkblog_can_interact_with_post(p_post_id uuid, p_user_id uuid)
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
              AND NOT public.inkblog_is_blocked_between(p.author_id, p_user_id)
       );
$$;

CREATE FUNCTION public.inkblog_can_read_target(
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
        RETURN public.inkblog_can_read_post(p_target_id, p_viewer_id);
    ELSIF p_target_type = 'comment' THEN
        SELECT p.author_id, c.author_id, p.status = 'published'
          INTO v_post_author, v_comment_author, v_published
          FROM public.inkblog_comments AS c
          JOIN public.inkblog_posts AS p ON p.id = c.post_id
         WHERE c.id = p_target_id;
        RETURN FOUND
           AND (p_viewer_id = v_post_author OR v_published)
           AND NOT public.inkblog_is_blocked_between(v_post_author, p_viewer_id)
           AND NOT public.inkblog_is_blocked_between(v_comment_author, p_viewer_id);
    END IF;
    RETURN false;
END;
$$;

CREATE FUNCTION public.inkblog_can_interact_with_target(
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
           AND NOT public.inkblog_is_blocked_between(v_post_author, p_user_id);
    ELSIF p_target_type = 'comment' THEN
        SELECT p.author_id, c.author_id, p.status = 'published'
          INTO v_post_author, v_comment_author, v_published
          FROM public.inkblog_comments AS c
          JOIN public.inkblog_posts AS p ON p.id = c.post_id
         WHERE c.id = p_target_id;
        RETURN FOUND
           AND v_published
           AND NOT public.inkblog_is_blocked_between(v_post_author, p_user_id)
           AND NOT public.inkblog_is_blocked_between(v_comment_author, p_user_id);
    END IF;
    RETURN false;
END;
$$;

CREATE FUNCTION public.inkblog_can_read_avatar_path(p_path text, p_viewer_id uuid)
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
          AND NOT public.inkblog_is_blocked_between(pr.id, p_viewer_id)
    );
$$;

CREATE FUNCTION public.inkblog_can_read_post_image_path(p_path text, p_viewer_id uuid)
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
          AND public.inkblog_can_read_post(i.post_id, p_viewer_id)
    );
$$;

CREATE FUNCTION public.inkblog_email_confirmed(p_user_id uuid)
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

CREATE FUNCTION public.inkblog_validate_profile_avatar()
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

CREATE FUNCTION public.inkblog_validate_post_image()
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

CREATE FUNCTION public.inkblog_set_post_timestamps()
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

CREATE FUNCTION public.inkblog_validate_comment()
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
        IF public.inkblog_is_blocked_between(NEW.author_id, v_parent_author) THEN
            RAISE EXCEPTION 'blocked users cannot reply to one another'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.inkblog_validate_polymorphic_target()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_exists boolean;
BEGIN
    IF TG_TABLE_NAME = 'inkblog_likes' AND TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'likes are immutable; delete and create a new like instead'
            USING ERRCODE = '42501';
    END IF;
    IF TG_TABLE_NAME = 'inkblog_reports' AND TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'reports are immutable'
            USING ERRCODE = '42501';
    END IF;

    IF TG_OP = 'UPDATE' AND (
        NEW.target_type IS DISTINCT FROM OLD.target_type
        OR NEW.target_id IS DISTINCT FROM OLD.target_id
        OR (TG_TABLE_NAME = 'inkblog_likes' AND NEW.user_id IS DISTINCT FROM OLD.user_id)
        OR (TG_TABLE_NAME = 'inkblog_reports' AND NEW.reporter_id IS DISTINCT FROM OLD.reporter_id)
    ) THEN
        RAISE EXCEPTION 'polymorphic target and owner are immutable'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.target_type = 'post' THEN
        SELECT EXISTS (SELECT 1 FROM public.inkblog_posts WHERE id = NEW.target_id) INTO v_exists;
    ELSIF NEW.target_type = 'comment' THEN
        SELECT EXISTS (SELECT 1 FROM public.inkblog_comments WHERE id = NEW.target_id) INTO v_exists;
    ELSE
        v_exists := false;
    END IF;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'InkBlog target does not exist' USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.inkblog_validate_notification()
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
                    AND public.inkblog_can_read_target(NEW.target_type, NEW.target_id, NEW.recipient_id);
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

CREATE FUNCTION public.inkblog_notify_follow()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NOT public.inkblog_is_blocked_between(NEW.follower_id, NEW.following_id) THEN
        INSERT INTO public.inkblog_notifications
            (recipient_id, actor_id, kind, target_type, target_id)
        VALUES
            (NEW.following_id, NEW.follower_id, 'follow', 'user', NEW.follower_id);
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.inkblog_notify_like()
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
       AND NOT public.inkblog_is_blocked_between(v_recipient, NEW.user_id) THEN
        INSERT INTO public.inkblog_notifications
            (recipient_id, actor_id, kind, target_type, target_id)
        VALUES
            (v_recipient, NEW.user_id, 'like', NEW.target_type, NEW.target_id);
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.inkblog_notify_comment()
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
       AND NOT public.inkblog_is_blocked_between(v_post_author, NEW.author_id) THEN
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
           AND NOT public.inkblog_is_blocked_between(v_parent_author, NEW.author_id) THEN
            INSERT INTO public.inkblog_notifications
                (recipient_id, actor_id, kind, target_type, target_id)
            VALUES
                (v_parent_author, NEW.author_id, 'reply', 'comment', NEW.id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.inkblog_cleanup_deleted_post_targets()
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

CREATE FUNCTION public.inkblog_cleanup_deleted_comment_targets()
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

CREATE FUNCTION public.inkblog_cleanup_block_relationships()
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

CREATE TRIGGER inkblog_profiles_validate_avatar
BEFORE INSERT OR UPDATE OF avatar_path ON public.inkblog_profiles
FOR EACH ROW EXECUTE FUNCTION public.inkblog_validate_profile_avatar();

CREATE TRIGGER inkblog_posts_timestamps
BEFORE INSERT OR UPDATE ON public.inkblog_posts
FOR EACH ROW EXECUTE FUNCTION public.inkblog_set_post_timestamps();

CREATE TRIGGER inkblog_post_images_validate
BEFORE INSERT OR UPDATE ON public.inkblog_post_images
FOR EACH ROW EXECUTE FUNCTION public.inkblog_validate_post_image();

CREATE TRIGGER inkblog_comments_validate
BEFORE INSERT OR UPDATE ON public.inkblog_comments
FOR EACH ROW EXECUTE FUNCTION public.inkblog_validate_comment();

CREATE TRIGGER inkblog_likes_validate_target
BEFORE INSERT OR UPDATE ON public.inkblog_likes
FOR EACH ROW EXECUTE FUNCTION public.inkblog_validate_polymorphic_target();

CREATE TRIGGER inkblog_reports_validate_target
BEFORE INSERT OR UPDATE ON public.inkblog_reports
FOR EACH ROW EXECUTE FUNCTION public.inkblog_validate_polymorphic_target();

CREATE TRIGGER inkblog_notifications_validate
BEFORE INSERT OR UPDATE ON public.inkblog_notifications
FOR EACH ROW EXECUTE FUNCTION public.inkblog_validate_notification();

CREATE TRIGGER inkblog_follows_notify
AFTER INSERT ON public.inkblog_follows
FOR EACH ROW EXECUTE FUNCTION public.inkblog_notify_follow();

CREATE TRIGGER inkblog_likes_notify
AFTER INSERT ON public.inkblog_likes
FOR EACH ROW EXECUTE FUNCTION public.inkblog_notify_like();

CREATE TRIGGER inkblog_comments_notify
AFTER INSERT ON public.inkblog_comments
FOR EACH ROW EXECUTE FUNCTION public.inkblog_notify_comment();

CREATE TRIGGER inkblog_posts_cleanup_targets
AFTER DELETE ON public.inkblog_posts
FOR EACH ROW EXECUTE FUNCTION public.inkblog_cleanup_deleted_post_targets();

CREATE TRIGGER inkblog_comments_cleanup_targets
AFTER DELETE ON public.inkblog_comments
FOR EACH ROW EXECUTE FUNCTION public.inkblog_cleanup_deleted_comment_targets();

CREATE TRIGGER inkblog_blocks_cleanup_relationships
AFTER INSERT ON public.inkblog_blocks
FOR EACH ROW EXECUTE FUNCTION public.inkblog_cleanup_block_relationships();

ALTER TABLE public.inkblog_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_post_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_follows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inkblog_blocks ENABLE ROW LEVEL SECURITY;

CREATE POLICY inkblog_profiles_read_visible
ON public.inkblog_profiles FOR SELECT TO anon, authenticated
USING (NOT public.inkblog_is_blocked_between(id, auth.uid()));
CREATE POLICY inkblog_profiles_insert_own
ON public.inkblog_profiles FOR INSERT TO authenticated
WITH CHECK (id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));
CREATE POLICY inkblog_profiles_update_own
ON public.inkblog_profiles FOR UPDATE TO authenticated
USING (id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()))
WITH CHECK (id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));
CREATE POLICY inkblog_profiles_delete_own
ON public.inkblog_profiles FOR DELETE TO authenticated
USING (id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

CREATE POLICY inkblog_posts_read_visible
ON public.inkblog_posts FOR SELECT TO anon, authenticated
USING (
    (status = 'published' OR author_id = auth.uid())
    AND NOT public.inkblog_is_blocked_between(author_id, auth.uid())
);
CREATE POLICY inkblog_posts_insert_own
ON public.inkblog_posts FOR INSERT TO authenticated
WITH CHECK (
    author_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
);
CREATE POLICY inkblog_posts_update_own
ON public.inkblog_posts FOR UPDATE TO authenticated
USING (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()))
WITH CHECK (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));
CREATE POLICY inkblog_posts_delete_own
ON public.inkblog_posts FOR DELETE TO authenticated
USING (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

CREATE POLICY inkblog_post_images_read_visible
ON public.inkblog_post_images FOR SELECT TO anon, authenticated
USING (public.inkblog_can_read_post(post_id, auth.uid()));
CREATE POLICY inkblog_post_images_insert_own
ON public.inkblog_post_images FOR INSERT TO authenticated
WITH CHECK (
    author_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND public.inkblog_owns_post(post_id, auth.uid())
);
CREATE POLICY inkblog_post_images_update_own
ON public.inkblog_post_images FOR UPDATE TO authenticated
USING (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()))
WITH CHECK (
    author_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND public.inkblog_owns_post(post_id, auth.uid())
);
CREATE POLICY inkblog_post_images_delete_own
ON public.inkblog_post_images FOR DELETE TO authenticated
USING (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

CREATE POLICY inkblog_follows_read_own
ON public.inkblog_follows FOR SELECT TO authenticated
USING (
    follower_id = auth.uid()
    AND NOT public.inkblog_is_blocked_between(follower_id, following_id)
);
CREATE POLICY inkblog_follows_insert_own
ON public.inkblog_follows FOR INSERT TO authenticated
WITH CHECK (
    follower_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND NOT public.inkblog_is_blocked_between(follower_id, following_id)
);
CREATE POLICY inkblog_follows_delete_own
ON public.inkblog_follows FOR DELETE TO authenticated
USING (follower_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

CREATE POLICY inkblog_likes_read_visible
ON public.inkblog_likes FOR SELECT TO anon, authenticated
USING (
    public.inkblog_can_read_target(target_type, target_id, auth.uid())
    AND NOT public.inkblog_is_blocked_between(user_id, auth.uid())
);
CREATE POLICY inkblog_likes_insert_own
ON public.inkblog_likes FOR INSERT TO authenticated
WITH CHECK (
    user_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND public.inkblog_can_interact_with_target(target_type, target_id, auth.uid())
);
CREATE POLICY inkblog_likes_delete_own
ON public.inkblog_likes FOR DELETE TO authenticated
USING (user_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

CREATE POLICY inkblog_comments_read_visible
ON public.inkblog_comments FOR SELECT TO anon, authenticated
USING (
    public.inkblog_can_read_post(post_id, auth.uid())
    AND NOT public.inkblog_is_blocked_between(author_id, auth.uid())
);
CREATE POLICY inkblog_comments_insert_own
ON public.inkblog_comments FOR INSERT TO authenticated
WITH CHECK (
    author_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND public.inkblog_can_interact_with_post(post_id, auth.uid())
);
CREATE POLICY inkblog_comments_update_own
ON public.inkblog_comments FOR UPDATE TO authenticated
USING (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()))
WITH CHECK (author_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));
CREATE POLICY inkblog_comments_delete_author_or_post_author
ON public.inkblog_comments FOR DELETE TO authenticated
USING (
    public.inkblog_email_confirmed(auth.uid())
    AND (author_id = auth.uid() OR public.inkblog_owns_post(post_id, auth.uid()))
);

CREATE POLICY inkblog_notifications_read_recipient
ON public.inkblog_notifications FOR SELECT TO authenticated
USING (
    recipient_id = auth.uid()
    AND NOT public.inkblog_is_blocked_between(recipient_id, actor_id)
);
CREATE POLICY inkblog_notifications_update_read_recipient
ON public.inkblog_notifications FOR UPDATE TO authenticated
USING (
    recipient_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND NOT public.inkblog_is_blocked_between(recipient_id, actor_id)
)
WITH CHECK (
    recipient_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND NOT public.inkblog_is_blocked_between(recipient_id, actor_id)
);

CREATE POLICY inkblog_reports_read_own
ON public.inkblog_reports FOR SELECT TO authenticated
USING (reporter_id = auth.uid());
CREATE POLICY inkblog_reports_insert_own
ON public.inkblog_reports FOR INSERT TO authenticated
WITH CHECK (
    reporter_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
    AND public.inkblog_can_interact_with_target(target_type, target_id, auth.uid())
);
CREATE POLICY inkblog_reports_delete_own
ON public.inkblog_reports FOR DELETE TO authenticated
USING (reporter_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

CREATE POLICY inkblog_blocks_read_own
ON public.inkblog_blocks FOR SELECT TO authenticated
USING (blocker_id = auth.uid());
CREATE POLICY inkblog_blocks_insert_own
ON public.inkblog_blocks FOR INSERT TO authenticated
WITH CHECK (
    blocker_id = auth.uid()
    AND public.inkblog_email_confirmed(auth.uid())
);
CREATE POLICY inkblog_blocks_delete_own
ON public.inkblog_blocks FOR DELETE TO authenticated
USING (blocker_id = auth.uid() AND public.inkblog_email_confirmed(auth.uid()));

-- Storage buckets remain private. Only the trusted edge function's service role
-- bypasses RLS to upload server-processed PNG objects.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
    ('inkblog-avatars', 'inkblog-avatars', false, 524288, ARRAY['image/png']::text[]),
    ('inkblog-images', 'inkblog-images', false, 2097152, ARRAY['image/png']::text[])
ON CONFLICT (id) DO NOTHING;

-- A permissive allow policy is necessary for PostgreSQL RLS, while these
-- restrictive guards also protect InkBlog buckets if another migration adds a
-- broad permissive storage.objects policy for authenticated clients.
CREATE POLICY inkblog_storage_read_authorized
ON storage.objects AS PERMISSIVE FOR SELECT TO anon, authenticated
USING (
    (bucket_id = 'inkblog-avatars'
        AND public.inkblog_can_read_avatar_path(name, auth.uid()))
    OR (bucket_id = 'inkblog-images'
        AND public.inkblog_can_read_post_image_path(name, auth.uid()))
);
CREATE POLICY inkblog_storage_read_guard
ON storage.objects AS RESTRICTIVE FOR SELECT TO anon, authenticated
USING (
    bucket_id NOT IN ('inkblog-avatars', 'inkblog-images')
    OR (bucket_id = 'inkblog-avatars'
        AND public.inkblog_can_read_avatar_path(name, auth.uid()))
    OR (bucket_id = 'inkblog-images'
        AND public.inkblog_can_read_post_image_path(name, auth.uid()))
);
CREATE POLICY inkblog_storage_insert_guard
ON storage.objects AS RESTRICTIVE FOR INSERT TO anon, authenticated
WITH CHECK (bucket_id NOT IN ('inkblog-avatars', 'inkblog-images'));
CREATE POLICY inkblog_storage_update_guard
ON storage.objects AS RESTRICTIVE FOR UPDATE TO anon, authenticated
USING (bucket_id NOT IN ('inkblog-avatars', 'inkblog-images'))
WITH CHECK (bucket_id NOT IN ('inkblog-avatars', 'inkblog-images'));
CREATE POLICY inkblog_storage_delete_guard
ON storage.objects AS RESTRICTIVE FOR DELETE TO anon, authenticated
USING (bucket_id NOT IN ('inkblog-avatars', 'inkblog-images'));

CREATE FUNCTION public.inkblog_list_posts(
    p_mode text DEFAULT 'discover',
    p_author uuid DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit integer DEFAULT 6,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    id uuid,
    author_id uuid,
    title text,
    markdown text,
    status text,
    created_at timestamptz,
    updated_at timestamptz,
    published_at timestamptz,
    display_name text,
    avatar_path text,
    like_count bigint,
    comment_count bigint,
    liked boolean,
    followed boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF p_mode NOT IN ('discover', 'feed', 'blog', 'mine') THEN
        RAISE EXCEPTION 'p_mode must be discover, feed, blog, or mine' USING ERRCODE = '22023';
    END IF;
    IF p_sort NOT IN ('newest', 'popular') THEN
        RAISE EXCEPTION 'p_sort must be newest or popular' USING ERRCODE = '22023';
    END IF;
    IF p_limit NOT BETWEEN 1 AND 50 OR p_offset NOT BETWEEN 0 AND 10_000 THEN
        RAISE EXCEPTION 'p_limit must be 1..50 and p_offset must be 0..10000' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH selected_posts AS (
        SELECT p.*
        FROM public.inkblog_posts AS p
        WHERE CASE p_mode
            WHEN 'discover' THEN p.status = 'published'
                               AND (p_author IS NULL OR p.author_id = p_author)
            WHEN 'feed' THEN p.status = 'published'
                           AND EXISTS (
                               SELECT 1
                               FROM public.inkblog_follows AS f
                               WHERE f.follower_id = auth.uid()
                                 AND f.following_id = p.author_id
                           )
            WHEN 'blog' THEN p.status = 'published'
                           AND p_author IS NOT NULL
                           AND p.author_id = p_author
            WHEN 'mine' THEN p.author_id = auth.uid()
        END
    ), post_rows AS (
        SELECT
            p.id,
            p.author_id,
            p.title,
            p.markdown,
            p.status,
            p.created_at,
            p.updated_at,
            p.published_at,
            pr.display_name,
            pr.avatar_path,
            ls.like_count,
            cs.comment_count,
            EXISTS (
                SELECT 1
                FROM public.inkblog_likes AS my_like
                WHERE my_like.user_id = auth.uid()
                  AND my_like.target_type = 'post'
                  AND my_like.target_id = p.id
            ) AS liked,
            EXISTS (
                SELECT 1
                FROM public.inkblog_follows AS my_follow
                WHERE my_follow.follower_id = auth.uid()
                  AND my_follow.following_id = p.author_id
            ) AS followed
        FROM selected_posts AS p
        LEFT JOIN public.inkblog_profiles AS pr ON pr.id = p.author_id
        CROSS JOIN LATERAL (
            SELECT count(*)::bigint AS like_count
            FROM public.inkblog_likes AS l
            WHERE l.target_type = 'post' AND l.target_id = p.id
        ) AS ls
        CROSS JOIN LATERAL (
            SELECT count(*)::bigint AS comment_count
            FROM public.inkblog_comments AS c
            WHERE c.post_id = p.id
        ) AS cs
    )
    SELECT
        r.id, r.author_id, r.title, r.markdown, r.status,
        r.created_at, r.updated_at, r.published_at,
        r.display_name, r.avatar_path, r.like_count, r.comment_count,
        r.liked, r.followed
    FROM post_rows AS r
    ORDER BY
        CASE WHEN p_sort = 'popular' THEN r.like_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'newest' THEN r.published_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'popular' THEN r.published_at END DESC NULLS LAST,
        r.id DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE FUNCTION public.inkblog_list_comments(
    p_post uuid,
    p_limit integer DEFAULT 6,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    id uuid,
    post_id uuid,
    author_id uuid,
    parent_id uuid,
    body text,
    created_at timestamptz,
    display_name text,
    avatar_path text,
    like_count bigint,
    liked boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF p_post IS NULL THEN
        RAISE EXCEPTION 'p_post is required' USING ERRCODE = '22023';
    END IF;
    IF p_limit NOT BETWEEN 1 AND 50 OR p_offset NOT BETWEEN 0 AND 10_000 THEN
        RAISE EXCEPTION 'p_limit must be 1..50 and p_offset must be 0..10000' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.post_id,
        c.author_id,
        c.parent_id,
        c.body,
        c.created_at,
        pr.display_name,
        pr.avatar_path,
        ls.like_count,
        EXISTS (
            SELECT 1
            FROM public.inkblog_likes AS my_like
            WHERE my_like.user_id = auth.uid()
              AND my_like.target_type = 'comment'
              AND my_like.target_id = c.id
        ) AS liked
    FROM public.inkblog_comments AS c
    LEFT JOIN public.inkblog_profiles AS pr ON pr.id = c.author_id
    CROSS JOIN LATERAL (
        SELECT count(*)::bigint AS like_count
        FROM public.inkblog_likes AS l
        WHERE l.target_type = 'comment' AND l.target_id = c.id
    ) AS ls
    WHERE c.post_id = p_post
    ORDER BY c.created_at ASC, c.id ASC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

GRANT SELECT ON public.inkblog_profiles TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.inkblog_profiles TO authenticated;
GRANT SELECT ON public.inkblog_posts TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.inkblog_posts TO authenticated;
GRANT SELECT ON public.inkblog_post_images TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.inkblog_post_images TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.inkblog_follows TO authenticated;
GRANT SELECT ON public.inkblog_likes TO anon, authenticated;
GRANT INSERT, DELETE ON public.inkblog_likes TO authenticated;
GRANT SELECT ON public.inkblog_comments TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.inkblog_comments TO authenticated;
GRANT SELECT, UPDATE ON public.inkblog_notifications TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.inkblog_reports TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.inkblog_blocks TO authenticated;
GRANT EXECUTE ON FUNCTION public.inkblog_list_posts(text, uuid, text, integer, integer)
    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.inkblog_list_comments(uuid, integer, integer)
    TO anon, authenticated;

REVOKE ALL ON FUNCTION public.inkblog_is_blocked_between(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_is_blocked_between(uuid, uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.inkblog_owns_post(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_owns_post(uuid, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.inkblog_can_read_post(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_can_read_post(uuid, uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.inkblog_can_interact_with_post(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_can_interact_with_post(uuid, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.inkblog_can_read_target(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_can_read_target(text, uuid, uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.inkblog_can_interact_with_target(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_can_interact_with_target(text, uuid, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.inkblog_can_read_avatar_path(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_can_read_avatar_path(text, uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.inkblog_can_read_post_image_path(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_can_read_post_image_path(text, uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.inkblog_email_confirmed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inkblog_email_confirmed(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.inkblog_validate_profile_avatar() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_validate_post_image() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_set_post_timestamps() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_validate_comment() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_validate_polymorphic_target() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_validate_notification() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_notify_follow() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_notify_like() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_notify_comment() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_cleanup_deleted_post_targets() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_cleanup_deleted_comment_targets() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.inkblog_cleanup_block_relationships() FROM PUBLIC;

COMMIT;
