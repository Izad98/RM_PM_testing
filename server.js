// Static file server for Azure App Service (Linux/Node plans).
//
// This app has no build step and no server-side logic of its own — every
// page (index.html, verify.html) talks directly to Supabase from the
// browser. This file's only job is to serve the static files so an Azure
// Web App has something to run; it does not add any backend behavior.
//
// If the Web App plan is Windows/IIS instead, this file and package.json
// are not used — see web.config instead. Details: AZURE_DEPLOYMENT.md.
const express = require('express');

const app = express();
const port = process.env.PORT || 8080;

// Allow-list, not a denylist: this directory also holds the SQL schema
// files, Edge Function source and deployment docs, none of which should
// be publicly downloadable just because express.static would happily
// serve anything under __dirname. Only the two pages and the image
// assets they actually reference get served; everything else 404s.
const ALLOWED_ASSET_EXT = /\.(ico|png)$/i;
app.use((req, res, next) => {
  const reqPath = req.path === '/' ? '/index.html' : req.path;
  const isPage = reqPath === '/index.html' || reqPath === '/verify.html';
  if (!isPage && !ALLOWED_ASSET_EXT.test(reqPath)) return res.status(404).send('Not found');
  next();
});

app.use(express.static(__dirname, { extensions: ['html'] }));
app.use((req, res) => res.status(404).send('Not found'));

app.listen(port, () => {
  console.log(`RM & PM Releasing Portal listening on port ${port}`);
});
