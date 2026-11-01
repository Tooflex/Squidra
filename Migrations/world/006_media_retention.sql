-- Optional bounded media storage; the immutable world journal is never changed.
CREATE TABLE retained_media (
    actor_id uuid NOT NULL,
    frame_id uuid NOT NULL,
    captured_us bigint NOT NULL CHECK (captured_us BETWEEN 0 AND 253402296000000000),
    expires_us bigint NOT NULL CHECK (expires_us > captured_us AND expires_us <= captured_us + 3600000000),
    media_type text NOT NULL CHECK (media_type IN ('image/png','image/jpeg')),
    byte_count integer NOT NULL CHECK (byte_count BETWEEN 1 AND 65536),
    blob bytea,
    unavailable_us bigint,
    reason text,
    PRIMARY KEY (actor_id, frame_id),
    CHECK ((blob IS NOT NULL AND octet_length(blob)=byte_count AND unavailable_us IS NULL AND reason IS NULL)
        OR (blob IS NULL AND unavailable_us IS NOT NULL AND reason IS NOT NULL AND unavailable_us >= captured_us AND unavailable_us <= 253402300800000000
            AND reason IN ('expired','erased'))),
    CHECK (reason IS DISTINCT FROM 'expired' OR unavailable_us >= expires_us)
);
CREATE INDEX retained_media_expiry ON retained_media(actor_id,expires_us,frame_id) WHERE blob IS NOT NULL;
CREATE FUNCTION protect_retained_media() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION 'Media references cannot be removed' USING ERRCODE='55000';
    END IF;
    IF ROW(NEW.actor_id,NEW.frame_id,NEW.captured_us,NEW.expires_us,NEW.media_type,NEW.byte_count)
        IS DISTINCT FROM ROW(OLD.actor_id,OLD.frame_id,OLD.captured_us,OLD.expires_us,OLD.media_type,OLD.byte_count)
        OR OLD.blob IS NULL OR NEW.blob IS NOT NULL THEN
        RAISE EXCEPTION 'Only irreversible media unavailability is allowed' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER retained_media_transition BEFORE UPDATE OR DELETE ON retained_media
FOR EACH ROW EXECUTE FUNCTION protect_retained_media();
CREATE TRIGGER retained_media_no_truncate BEFORE TRUNCATE ON retained_media
FOR EACH STATEMENT EXECUTE FUNCTION protect_retained_media();
