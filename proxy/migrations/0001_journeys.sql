-- How people get around the app, as the app's Journey sends it (see recordJourney in src/index.ts): one row
-- per event, so an event sent twice is kept once (see 0003 for the key).
CREATE TABLE events (
  install   TEXT    NOT NULL,  -- the install's random ID
  seq       INTEGER NOT NULL,  -- the event's number on that install
  at        INTEGER NOT NULL,  -- when it happened, seconds since 1970
  arrived   INTEGER NOT NULL,  -- when the proxy got it
  kind      TEXT    NOT NULL,  -- open | screen | tap | exit | crash | hang
  name      TEXT    NOT NULL,  -- a screen or button
  detail    TEXT    NOT NULL DEFAULT '',
  came      TEXT    NOT NULL DEFAULT '',  -- the screen it happened on, or came from
  session   TEXT    NOT NULL,
  city      TEXT    NOT NULL DEFAULT '',
  version   TEXT    NOT NULL DEFAULT '',
  favorites INTEGER NOT NULL DEFAULT 0,
  seconds   INTEGER NOT NULL DEFAULT 0,  -- on the screen it came from, or the session's length
  PRIMARY KEY (install, seq)
);
CREATE INDEX events_at ON events (at);
CREATE INDEX events_session ON events (session, at);
