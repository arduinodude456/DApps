-- Cover frequently joined InkBlog foreign keys; do not modify the existing DChat indexes.
CREATE INDEX IF NOT EXISTS inkblog_comments_author_id_idx
    ON public.inkblog_comments (author_id);
CREATE INDEX IF NOT EXISTS inkblog_notifications_actor_id_idx
    ON public.inkblog_notifications (actor_id);
CREATE INDEX IF NOT EXISTS inkblog_post_images_author_id_idx
    ON public.inkblog_post_images (author_id);
CREATE INDEX IF NOT EXISTS inkblog_reports_reporter_id_idx
    ON public.inkblog_reports (reporter_id);
