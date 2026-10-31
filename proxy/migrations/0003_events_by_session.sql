-- An event is kept once per install, session and number: app builds before numbers went on from launch to
-- launch start again at 1 every launch, and each launch is a new session.
CREATE TABLE events_new (
  install   TEXT    NOT NULL,
  seq       INTEGER NOT NULL,
  at        INTEGER NOT NULL,
  arrived   INTEGER NOT NULL,
  kind      TEXT    NOT NULL,
  name      TEXT    NOT NULL,
  detail    TEXT    NOT NULL DEFAULT '',
  came      TEXT    NOT NULL DEFAULT '',
  session   TEXT    NOT NULL,
  city      TEXT    NOT NULL DEFAULT '',
  version   TEXT    NOT NULL DEFAULT '',
  favorites INTEGER NOT NULL DEFAULT 0,
  seconds   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (install, session, seq)
);
INSERT INTO events_new SELECT install, seq, at, arrived, kind, name, detail, came, session, city, version, favorites, seconds FROM events;
DROP TABLE events;
ALTER TABLE events_new RENAME TO events;
CREATE INDEX events_at ON events (at);
CREATE INDEX events_session ON events (session, at);
CREATE INDEX events_install ON events (install, at);
