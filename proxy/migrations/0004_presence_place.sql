-- Where the phone is, roughly: the place Cloudflare guesses from the request's IP address (a city or
-- region, "Oakland, CA"), and its coordinates to a tenth of a degree, about 10 km. The IP address
-- itself isn't kept. See recordPresence in src/index.ts.
ALTER TABLE presence ADD COLUMN place TEXT NOT NULL DEFAULT '';
ALTER TABLE presence ADD COLUMN lat REAL;
ALTER TABLE presence ADD COLUMN lon REAL;
