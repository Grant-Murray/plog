DROP ROLE IF EXISTS "grant";
CREATE ROLE "grant" LOGIN SUPERUSER;

DROP SCHEMA plog CASCADE;
CREATE SCHEMA plog;

DROP TABLE IF EXISTS plog.user CASCADE;
/* Shadow of session.user, it is necessary to have a shadow table because
   references to session.user would break the API barrier around the 
   session service and couple the services too tightly. */
CREATE TABLE plog.user (
  user_id VARCHAR(256) NOT NULL PRIMARY KEY,
  session_user_id VARCHAR(256) UNIQUE /* reference to remote session.user */
);

DROP TABLE IF EXISTS plog.album CASCADE;
CREATE TABLE plog.album (
  album_id INTEGER NOT NULL PRIMARY KEY,
  dir_name VARCHAR(256) NOT NULL UNIQUE,
  album_dt TIMESTAMP WITH TIME ZONE NOT NULL
);

DROP TABLE IF EXISTS plog.event CASCADE;
CREATE TABLE plog.event (
  event_id INTEGER NOT NULL PRIMARY KEY,
  album_id INTEGER REFERENCES plog.album,
  title VARCHAR(256)
);

DROP TABLE IF EXISTS plog.image CASCADE;
CREATE TABLE plog.image (
  image_id INTEGER NOT NULL PRIMARY KEY,
  album_id INTEGER REFERENCES plog.album,
  event_id INTEGER REFERENCES plog.event,
  filename VARCHAR(256) NOT NULL,
  height INTEGER NOT NULL,
  width INTEGER NOT NULL,
  size_bytes INTEGER NOT NULL,
  created_dt TIMESTAMP WITH TIME ZONE NOT NULL,
  uploaded_dt TIMESTAMP WITH TIME ZONE NOT NULL
);

DROP TABLE IF EXISTS plog.comment CASCADE;
CREATE TABLE plog.comment (
  comment_id INTEGER NOT NULL PRIMARY KEY,

  event_id INTEGER REFERENCES plog.event, /* null means it is an image comment */
  image_id INTEGER REFERENCES plog.image, /* null means it is an event comment */

  added_by VARCHAR(256) REFERENCES plog.user, 
  added_dt TIMESTAMP WITH TIME ZONE NOT NULL,
  modified_dt TIMESTAMP WITH TIME ZONE NOT NULL,
  text TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS plog.log (
  entered timestamp with time zone,
  level VARCHAR(16),
  msg text
);
INSERT INTO plog.log VALUES (now(), 'Info', 'table created');

/* Conversion from gallery */
\i ~/glm-go/src/gopkgs.grantmurray.com/config/config-pg-schema.sql
\i ~/glm-go/src/gopkgs.grantmurray.com/session/session-pg-schema.sql
\i /tmp/mydump-for-postgres.FIXED.sql
SET search_path TO gallery,plog,public;

ALTER TABLE gallery.album ADD COLUMN new_id INTEGER;
DROP SEQUENCE IF EXISTS conv_seq;
CREATE SEQUENCE conv_seq;
DROP FUNCTION IF EXISTS assign_new_album_ids();
CREATE FUNCTION assign_new_album_ids() RETURNS INTEGER AS $$
DECLARE
  rec RECORD;
BEGIN
  PERFORM setval('conv_seq', 1, false);
  FOR rec IN SELECT * FROM gallery.album order by al_date ASC LOOP
    UPDATE gallery.album SET new_id = nextval('conv_seq') where al_id = rec.al_id;
  END LOOP;
  RETURN 1;
END;
$$ LANGUAGE plpgsql;
SELECT assign_new_album_ids();

ALTER TABLE gallery.album_event ADD COLUMN new_id INTEGER;
DROP FUNCTION IF EXISTS assign_new_album_event_ids();
CREATE FUNCTION assign_new_album_event_ids() RETURNS INTEGER AS $$
DECLARE
  rec RECORD;
BEGIN
  PERFORM setval('conv_seq', 1, false);
  FOR rec IN SELECT * FROM gallery.album_event order by ae_start_dt ASC LOOP
    UPDATE gallery.album_event SET new_id = nextval('conv_seq') where ae_id = rec.ae_id and ae_album = rec.ae_album;
  END LOOP;
  RETURN 1;
END;
$$ LANGUAGE plpgsql;
SELECT assign_new_album_event_ids();
SELECT ae_id, ae_start_dt, ae_title, new_id FROM album_event ORDER BY ae_start_dt ASC LIMIT 10;

ALTER TABLE gallery.image ADD COLUMN new_id INTEGER;
DROP FUNCTION IF EXISTS assign_new_image_ids();
CREATE FUNCTION assign_new_image_ids() RETURNS INTEGER AS $$
DECLARE
  rec RECORD;
BEGIN
  PERFORM setval('conv_seq', 1, false);
  FOR rec IN SELECT * FROM gallery.image order by im_created ASC LOOP
    UPDATE gallery.image SET new_id = nextval('conv_seq') where im_id = rec.im_id and im_album = rec.im_album and im_event = rec.im_event;
  END LOOP;
  RETURN 1;
END;
$$ LANGUAGE plpgsql;
SELECT assign_new_image_ids();
SELECT * FROM image ORDER BY im_created ASC LIMIT 10;

DROP TABLE IF EXISTS gallery.new_comment;
CREATE TABLE gallery.new_comment (
  new_id INTEGER,
  new_event_id INTEGER, /* null means it is an image comment */
  new_image_id INTEGER, /* null means it is an event comment */

  ec_album INTEGER,
  ec_event INTEGER,
  ec_comment_id INTEGER,

  ic_image INTEGER,
  ic_comment_id INTEGER,
  
  old_added_by VARCHAR(256),

  added_dt TIMESTAMP WITH TIME ZONE NOT NULL,
  modified_dt TIMESTAMP WITH TIME ZONE NOT NULL,
  text TEXT NOT NULL
);
INSERT INTO gallery.new_comment(ec_album, ec_event, ec_comment_id, old_added_by, added_dt, modified_dt, text)
  SELECT ec_album, ec_event, ec_comment_id, ec_added_by, ec_added_dt, ec_modified_dt, ec_text from gallery.event_comment;
INSERT INTO gallery.new_comment(ic_image, ic_comment_id, old_added_by, added_dt, modified_dt, text)
  SELECT ic_image, ic_comment_id, ic_added_by, ic_added_dt, ic_modified_dt, ic_text from gallery.image_comment;

DROP FUNCTION IF EXISTS assign_new_comment_ids();
CREATE FUNCTION assign_new_comment_ids() RETURNS INTEGER AS $$
DECLARE
  rec RECORD;
BEGIN
  PERFORM setval('conv_seq', 1, false);
  FOR rec IN SELECT * FROM gallery.new_comment order by added_dt ASC LOOP
    UPDATE gallery.new_comment SET new_id = nextval('conv_seq') 
      WHERE (ic_image > 0 and ic_image = rec.ic_image and ic_comment_id = rec.ic_comment_id) or 
            (ec_comment_id > 0 and ec_album = rec.ec_album and ec_event = rec.ec_event and ec_comment_id = rec.ec_comment_id);
  END LOOP;
  RETURN 1;
END;
$$ LANGUAGE plpgsql;
SELECT assign_new_comment_ids();

UPDATE gallery.new_comment as nc set new_event_id = (select new_id from gallery.album_event where ae_album = nc.ec_album and ae_id = nc.ec_event) where nc.ec_album is not null and nc.ec_album > 0;
UPDATE gallery.new_comment as nc set new_image_id = (select new_id from gallery.image where im_id = nc.ic_image) where nc.ic_image is not null and nc.ic_image > 0;

SELECT new_id, new_event_id, new_image_id, ec_album, ec_event, ec_comment_id, ic_image, ic_comment_id, added_dt FROM new_comment ORDER BY added_dt, new_id ASC LIMIT 10;

/*************/
INSERT INTO plog.album ( album_id, dir_name, album_dt ) 
  SELECT new_id, al_dirname, al_date FROM gallery.album;

INSERT INTO plog.event ( event_id, album_id, title)
  SELECT ev.new_id, (SELECT al.new_id FROM gallery.album AS al WHERE al.al_id = ev.ae_album), ae_title
  FROM gallery.album_event AS ev;

INSERT INTO plog.image ( image_id, album_id, event_id, filename, height, width, size_bytes, created_dt, uploaded_dt) 
  SELECT im.new_id, (SELECT al.new_id FROM gallery.album AS al WHERE al.al_id = im.im_album),
    (SELECT ev.new_id FROM gallery.album_event AS ev WHERE ev.ae_id = im.im_event and ev.ae_album = im.im_album), 
    im_filename, im_height, im_width, im_size, im_created, im_uploaded FROM gallery.image AS im;

/* TODO fix users to match session.user s/old_added_by/sys_user_id/ */
INSERT INTO plog.user (user_id) 
  SELECT distinct(old_added_by) FROM gallery.new_comment;

INSERT INTO plog.comment ( comment_id, event_id, image_id, added_by, added_dt, modified_dt, text )
  SELECT new_id, new_event_id, new_image_id, old_added_by, added_dt, modified_dt, text FROM gallery.new_comment;
