// Static file server for Azure App Service (Linux/Node plans).
//
// This app has no build step and no server-side logic of its own — every
// page (index.html, verify.html) talks directly to Supabase from the
// browser. This file's only job is to serve the static files so an Azure
// Web App has something to run; it does not add any backend behavior.
//
// If the Web App plan is Windows/IIS instead, this file and package.json
// are not used — see web.config instead. Details: AZURE_DEPLOYMENT.md.
//
// Deliberately not express.static(__dirname, ...): this directory also
// holds the SQL schema files, Edge Function source and deployment docs,
// none of which should be publicly downloadable. CodeQL flags exactly
// that pattern (js/exposure-of-private-files) because express.static
// still holds the capability to serve the whole directory even from
// behind a filter — see github.com/Izad98/RM_PM_testing/security/
// code-scanning/7. Each servable file is instead named explicitly below
// and served with res.sendFile(), which grants no directory-listing or
// traversal capability at all: only these exact, hardcoded files can
// ever be returned, regardless of what a request path says.
const express = require('express');
const rateLimit = require('express-rate-limit');

const app = express();
const port = process.env.PORT || 8080;

// Azure App Service sits behind a reverse proxy, so without this every
// request would appear to come from that proxy's own IP — which would
// make the rate limiter below either a no-op or, worse, bucket every
// real visitor together as a single client. `1` trusts exactly one
// proxy hop (Azure's front end), which is the correct value here and
// avoids the "trust all X-Forwarded-For" mistake of `true`.
app.set('trust proxy', 1);

// CodeQL (js/missing-rate-limiting) flags the file-serving route below
// since it does a filesystem access per request — see security/code-
// scanning/8. The limit is generous on purpose: this is a small internal
// tool, and colleagues on the same office network can share one apparent
// IP behind a corporate NAT, so it's sized to never bother real use while
// still bounding a scripted flood.
app.use(rateLimit({
  windowMs: 60 * 1000,
  limit: 120,
  standardHeaders: true,
  legacyHeaders: false,
}));

const FILES = {
  '/': 'index.html',
  '/index.html': 'index.html',
  '/verify.html': 'verify.html',
  '/favicon.ico': 'favicon.ico',
  '/favicon-16.png': 'favicon-16.png',
  '/favicon-32.png': 'favicon-32.png',
  '/apple-touch-icon.png': 'apple-touch-icon.png',
  '/hcb logo.png': 'hcb logo.png',
  '/hcb logo dark.png': 'hcb logo dark.png',
};

app.use((req, res) => {
  let reqPath;
  try {
    reqPath = decodeURIComponent(req.path);
  } catch {
    return res.status(404).send('Not found');
  }
  const file = FILES[reqPath];
  if (!file) return res.status(404).send('Not found');
  res.sendFile(file, { root: __dirname });
});

app.listen(port, () => {
  console.log(`RM & PM Releasing Portal listening on port ${port}`);
});
