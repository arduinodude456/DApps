-- InkBlog RLS regression test for Supabase execute_sql: DML only, all fixtures roll back.
BEGIN;

DO $$
DECLARE
    alice_uuid uuid := gen_random_uuid();
    bob_uuid uuid := gen_random_uuid();
    avatar_object_uuid uuid := gen_random_uuid();
    published_post_uuid uuid := gen_random_uuid();
    draft_post_uuid uuid := gen_random_uuid();
    published_image_uuid uuid := gen_random_uuid();
    draft_image_uuid uuid := gen_random_uuid();
    unprocessed_image_uuid uuid := gen_random_uuid();
    root_comment_uuid uuid := gen_random_uuid();
    moderated_comment_uuid uuid := gen_random_uuid();
    reply_comment_uuid uuid := gen_random_uuid();
    deep_reply_uuid uuid := gen_random_uuid();
    report_uuid uuid := gen_random_uuid();
    notification_uuid uuid;
    avatar_path text := alice_uuid::text || '/' || avatar_object_uuid::text || '.png';
    published_image_path text := alice_uuid::text || '/' || published_post_uuid::text || '/' || published_image_uuid::text || '.png';
    draft_image_path text := alice_uuid::text || '/' || draft_post_uuid::text || '/' || draft_image_uuid::text || '.png';
    ok boolean;
BEGIN
    -- execute_sql starts as postgres: insert only transaction-local synthetic fixtures.
    INSERT INTO auth.users (
        id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) VALUES
        (alice_uuid, 'authenticated', 'authenticated',
         'inkblog-alice-' || alice_uuid::text || '@example.test', 'not-used', clock_timestamp(),
         '{}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp()),
        (bob_uuid, 'authenticated', 'authenticated',
         'inkblog-bob-' || bob_uuid::text || '@example.test', 'not-used', clock_timestamp(),
         '{}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp());

    INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES
        ('inkblog-avatars', avatar_path, alice_uuid,
         jsonb_build_object('mimetype', 'image/png', 'width', '128', 'height', '128')),
        ('inkblog-images', published_image_path, alice_uuid,
         jsonb_build_object('mimetype', 'image/png', 'width', '800', 'height', '1000')),
        ('inkblog-images', draft_image_path, alice_uuid,
         jsonb_build_object('mimetype', 'image/png', 'width', '320', 'height', '240'));

    PERFORM set_config('request.jwt.claim.sub', alice_uuid::text, true);
    PERFORM set_config('role', 'authenticated', true);

    INSERT INTO public.inkblog_profiles (id, display_name, bio, avatar_path)
    VALUES (alice_uuid, 'Alice', 'author', avatar_path);
    INSERT INTO public.inkblog_posts (id, author_id, title, markdown, status)
    VALUES
        (published_post_uuid, alice_uuid, 'Published post', 'public text', 'published'),
        (draft_post_uuid, alice_uuid, 'Draft post', 'private text', 'draft');
    INSERT INTO public.inkblog_post_images (post_id, author_id, path, alt_text, width, height)
    VALUES
        (published_post_uuid, alice_uuid, published_image_path, 'cover', 800, 1000),
        (draft_post_uuid, alice_uuid, draft_image_path, 'draft cover', 320, 240);

    BEGIN
        UPDATE public.inkblog_profiles
           SET avatar_path = 'https://example.test/not-an-object.png'
         WHERE id = alice_uuid;
        RAISE EXCEPTION 'arbitrary avatar URL unexpectedly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO public.inkblog_post_images (post_id, author_id, path, alt_text, width, height)
        VALUES (
            published_post_uuid, alice_uuid,
            alice_uuid::text || '/' || published_post_uuid::text || '/' || unprocessed_image_uuid::text || '.png',
            'unprocessed client reference', 1, 1
        );
        RAISE EXCEPTION 'post image metadata accepted without a processed storage object';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    SELECT count(*) = 1 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-images' AND o.name = draft_image_path
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'draft author cannot read own private image';
    END IF;
    SELECT count(*) = 2 INTO ok
      FROM public.inkblog_list_posts('mine', NULL, 'newest', 6, 0) AS p
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'author list does not include own draft and published post';
    END IF;

    PERFORM set_config('request.jwt.claim.sub', bob_uuid::text, true);
    INSERT INTO public.inkblog_profiles (id, display_name, bio)
    VALUES (bob_uuid, 'Bob', 'reader');

    SELECT count(*) = 0 INTO ok
      FROM public.inkblog_posts AS p
     WHERE p.id = draft_post_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'another user can read a draft';
    END IF;
    SELECT EXISTS (
        SELECT p.id
          FROM public.inkblog_list_posts('discover', NULL, 'newest', 6, 0) AS p
         WHERE p.id = published_post_uuid
         LIMIT 1
    ) INTO ok LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'published post is not discoverable';
    END IF;
    SELECT count(*) = 1 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-avatars' AND o.name = avatar_path
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'visible profile avatar is unreadable';
    END IF;
    SELECT count(*) = 1 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-images' AND o.name = published_image_path
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'published post image is unreadable';
    END IF;
    SELECT count(*) = 0 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-images' AND o.name = draft_image_path
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'another user can read a draft image';
    END IF;

    UPDATE public.inkblog_posts
       SET title = 'forged by Bob'
     WHERE id = published_post_uuid;
    SELECT p.title = 'Published post' INTO ok
      FROM public.inkblog_posts AS p
     WHERE p.id = published_post_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'foreign post update was accepted';
    END IF;
    DELETE FROM public.inkblog_posts WHERE id = published_post_uuid;
    SELECT count(*) = 1 INTO ok
      FROM public.inkblog_posts AS p
     WHERE p.id = published_post_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'foreign post delete was accepted';
    END IF;
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner, metadata)
        VALUES (
            'inkblog-avatars', bob_uuid::text || '/' || gen_random_uuid()::text || '.png', bob_uuid,
            jsonb_build_object('mimetype', 'image/png', 'width', '128', 'height', '128')
        );
        RAISE EXCEPTION 'direct InkBlog storage upload unexpectedly accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    INSERT INTO public.inkblog_follows (follower_id, following_id)
    VALUES (bob_uuid, alice_uuid);
    SELECT EXISTS (
        SELECT p.id
          FROM public.inkblog_list_posts('feed', NULL, 'newest', 6, 0) AS p
         WHERE p.id = published_post_uuid AND p.followed
         LIMIT 1
    ) INTO ok LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'follow does not produce a visible feed item';
    END IF;
    INSERT INTO public.inkblog_comments (id, post_id, author_id, body)
    VALUES
        (root_comment_uuid, published_post_uuid, bob_uuid, 'Bob root comment'),
        (moderated_comment_uuid, published_post_uuid, bob_uuid, 'comment to moderate');
    INSERT INTO public.inkblog_reports (id, reporter_id, target_type, target_id, reason)
    VALUES (report_uuid, bob_uuid, 'post', published_post_uuid, 'test moderation report');
    SELECT count(*) = 1 INTO ok
      FROM public.inkblog_reports AS r
     WHERE r.id = report_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'reporter cannot read own report';
    END IF;

    PERFORM set_config('request.jwt.claim.sub', alice_uuid::text, true);
    SELECT count(*) = 0 INTO ok
      FROM public.inkblog_reports AS r
     WHERE r.id = report_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'non-reporter can read a private moderation report';
    END IF;
    INSERT INTO public.inkblog_likes (user_id, target_type, target_id)
    VALUES (alice_uuid, 'comment', root_comment_uuid);
    SELECT EXISTS (
        SELECT c.id
          FROM public.inkblog_list_comments(published_post_uuid, 6, 0) AS c
         WHERE c.id = root_comment_uuid AND c.liked AND c.like_count = 1
         LIMIT 1
    ) INTO ok LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'comment like is not counted and returned as liked';
    END IF;
    INSERT INTO public.inkblog_comments (id, post_id, author_id, parent_id, body)
    VALUES (reply_comment_uuid, published_post_uuid, alice_uuid, root_comment_uuid, 'Alice reply');
    DELETE FROM public.inkblog_comments WHERE id = moderated_comment_uuid;
    SELECT count(*) = 0 INTO ok
      FROM public.inkblog_comments AS c
     WHERE c.id = moderated_comment_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'post author cannot delete another user comment';
    END IF;
    BEGIN
        INSERT INTO public.inkblog_comments (id, post_id, author_id, parent_id, body)
        VALUES (deep_reply_uuid, published_post_uuid, alice_uuid, reply_comment_uuid, 'illegal second-depth reply');
        RAISE EXCEPTION 'second-depth reply unexpectedly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    SELECT n.id INTO notification_uuid
      FROM public.inkblog_notifications AS n
     WHERE n.recipient_id = alice_uuid
       AND n.actor_id = bob_uuid
       AND n.kind = 'follow'
       AND n.target_type = 'user'
       AND n.target_id = bob_uuid
     LIMIT 1;
    IF notification_uuid IS NULL THEN
        RAISE EXCEPTION 'follow notification was not generated';
    END IF;
    UPDATE public.inkblog_notifications
       SET read_at = clock_timestamp()
     WHERE id = notification_uuid;
    SELECT n.read_at IS NOT NULL INTO ok
      FROM public.inkblog_notifications AS n
     WHERE n.id = notification_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'recipient cannot update notification read_at';
    END IF;
    BEGIN
        UPDATE public.inkblog_notifications SET kind = 'like' WHERE id = notification_uuid;
        RAISE EXCEPTION 'notification payload mutation unexpectedly accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        INSERT INTO public.inkblog_notifications
            (recipient_id, actor_id, kind, target_type, target_id)
        VALUES (bob_uuid, alice_uuid, 'follow', 'user', alice_uuid);
        RAISE EXCEPTION 'forged notification unexpectedly accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    SELECT count(*) = 4 INTO ok
      FROM pg_policies AS p
     WHERE p.schemaname = 'storage'
       AND p.tablename = 'objects'
       AND p.policyname IN (
           'inkblog_storage_read_guard', 'inkblog_storage_insert_guard',
           'inkblog_storage_update_guard', 'inkblog_storage_delete_guard'
       )
       AND p.permissive = 'RESTRICTIVE'
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'InkBlog storage restrictive guards are missing';
    END IF;

    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('role', 'anon', true);
    SELECT count(*) = 1 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-images' AND o.name = published_image_path
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'anonymous caller cannot read a published post image';
    END IF;
    SELECT count(*) = 0 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id = 'inkblog-images' AND o.name = draft_image_path
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'anonymous caller can read a draft image';
    END IF;

    PERFORM set_config('request.jwt.claim.sub', bob_uuid::text, true);
    PERFORM set_config('role', 'authenticated', true);
    INSERT INTO public.inkblog_blocks (blocker_id, blocked_id)
    VALUES (bob_uuid, alice_uuid);
    SELECT count(*) = 1 INTO ok
      FROM public.inkblog_blocks AS b
     WHERE b.blocker_id = bob_uuid AND b.blocked_id = alice_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'blocker cannot read own block';
    END IF;
    SELECT count(*) = 0 INTO ok
      FROM public.inkblog_list_posts('feed', NULL, 'newest', 6, 0) AS p
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'block does not remove feed interaction';
    END IF;
    SELECT count(*) = 0 INTO ok
      FROM public.inkblog_posts AS p
     WHERE p.id = published_post_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'block does not hide published post from blocker';
    END IF;
    SELECT count(*) = 1 INTO ok
      FROM public.inkblog_reports AS r
     WHERE r.id = report_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'block cleanup erased the reporter complaint';
    END IF;
    SELECT count(*) = 0 INTO ok
      FROM storage.objects AS o
     WHERE o.bucket_id IN ('inkblog-avatars', 'inkblog-images')
       AND o.name IN (avatar_path, published_image_path)
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'block does not hide avatar and published image';
    END IF;
    BEGIN
        INSERT INTO public.inkblog_follows (follower_id, following_id)
        VALUES (bob_uuid, alice_uuid);
        RAISE EXCEPTION 'blocked follow unexpectedly accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    PERFORM set_config('request.jwt.claim.sub', alice_uuid::text, true);
    SELECT count(*) = 0 INTO ok
      FROM public.inkblog_profiles AS p
     WHERE p.id = bob_uuid
     LIMIT 1;
    IF ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'block does not hide in the reverse direction';
    END IF;
END;
$$;

ROLLBACK;
