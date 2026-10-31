-- Who's around: a row per install, kept current by its requests (see recordPresence in src/index.ts), for the
-- stats page's live view. The city is the one its last request was for; nothing else about where.
CREATE TABLE presence (
  install     TEXT    PRIMARY KEY,
  city        TEXT    NOT NULL DEFAULT '',
  version     TEXT    NOT NULL DEFAULT '',
  favorites   INTEGER NOT NULL DEFAULT 0,
  first_seen  INTEGER NOT NULL,           -- seconds since 1970
  last_seen   INTEGER NOT NULL,           -- any request: the app, the map, a widget
  last_app    INTEGER NOT NULL DEFAULT 0, -- the app (or its live map) asking: it's in front
  last_widget INTEGER NOT NULL DEFAULT 0,
  away        INTEGER NOT NULL DEFAULT 0  -- when it was last put away
);
CREATE INDEX presence_last ON presence (last_seen);
