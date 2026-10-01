// Keeps only the original-language audio and the TDARR_SUBTITLE_LANGS subtitles.
// The original language comes from Radarr/Sonarr, matched by folder: Tdarr
// mounts the library at the same container paths the arr apps use
// (/media/movies, /media/series), so a file's path starts with its
// movie's/series' `path`.
//
// Configured by environment only (docker-compose.tdarr.yml), never by plugin
// inputs: inputs live in Tdarr's database, and an API key copied there goes
// stale the day the key rotates.
//
// No npm dependencies on purpose: Tdarr installs a plugin's `dependencies` from
// the registry at run time, which would make this plugin's behavior depend on
// whatever version npm serves that day.

const http = require('http');

const details = () => ({
  id: 'Tdarr_Plugin_nas_keep_original_audio',
  Stage: 'Pre-processing',
  Name: 'Keep original audio + chosen subtitles',
  Type: 'Audio',
  Operation: 'Transcode',
  Description: 'Removes audio tracks not in the original language (from Radarr/Sonarr) '
    + 'and subtitle tracks not in TDARR_SUBTITLE_LANGS. Stream copy, no re-encode.',
  Version: '1.0',
  Tags: 'pre-processing,ffmpeg,audio only,subtitle only',
  Inputs: [],
});

// One group per language: ISO 639-2/B (what mkvmerge writes), 639-2/T, and
// 639-1, since files in the wild carry any of the three. Keys are the
// Language names Radarr v6.4.4 / Sonarr v4.0.20 return as originalLanguage.name.
const LANGUAGE_CODES = {
  English: ['eng', 'en'],
  French: ['fre', 'fra', 'fr'],
  Spanish: ['spa', 'es'],
  'Spanish (Latino)': ['spa', 'es'],
  German: ['ger', 'deu', 'de'],
  Italian: ['ita', 'it'],
  Danish: ['dan', 'da'],
  Dutch: ['dut', 'nld', 'nl'],
  Flemish: ['dut', 'nld', 'nl'],
  Japanese: ['jpn', 'ja'],
  Icelandic: ['ice', 'isl', 'is'],
  Chinese: ['chi', 'zho', 'zh', 'cmn', 'yue'],
  Russian: ['rus', 'ru'],
  Polish: ['pol', 'pl'],
  Vietnamese: ['vie', 'vi'],
  Swedish: ['swe', 'sv'],
  Norwegian: ['nor', 'nob', 'nno', 'no', 'nb', 'nn'],
  Finnish: ['fin', 'fi'],
  Turkish: ['tur', 'tr'],
  Portuguese: ['por', 'pt'],
  'Portuguese (Brazil)': ['por', 'pt'],
  Greek: ['gre', 'ell', 'el'],
  Korean: ['kor', 'ko'],
  Hungarian: ['hun', 'hu'],
  Hebrew: ['heb', 'he'],
  Lithuanian: ['lit', 'lt'],
  Czech: ['cze', 'ces', 'cs'],
  Hindi: ['hin', 'hi'],
  Romanian: ['rum', 'ron', 'ro'],
  Thai: ['tha', 'th'],
  Bulgarian: ['bul', 'bg'],
  Arabic: ['ara', 'ar'],
  Ukrainian: ['ukr', 'uk'],
  Persian: ['per', 'fas', 'fa'],
  Bengali: ['ben', 'bn'],
  Slovak: ['slo', 'slk', 'sk'],
  Latvian: ['lav', 'lv'],
  Catalan: ['cat', 'ca'],
  Croatian: ['hrv', 'hr'],
  Serbian: ['srp', 'sr'],
  Bosnian: ['bos', 'bs'],
  Estonian: ['est', 'et'],
  Tamil: ['tam', 'ta'],
  Indonesian: ['ind', 'id'],
  Telugu: ['tel', 'te'],
  Macedonian: ['mac', 'mkd', 'mk'],
  Slovenian: ['slv', 'sl'],
  Malayalam: ['mal', 'ml'],
  Kannada: ['kan', 'kn'],
  Albanian: ['alb', 'sqi', 'sq'],
  Afrikaans: ['afr', 'af'],
  Marathi: ['mar', 'mr'],
  Tagalog: ['tgl', 'tl', 'fil'],
  Urdu: ['urd', 'ur'],
  Romansh: ['roh', 'rm'],
  Mongolian: ['mon', 'mn'],
  Georgian: ['geo', 'kat', 'ka'],
};

// "rum" in TDARR_SUBTITLE_LANGS must also match a track tagged "ron" or "ro".
const expandCodes = (codes) => {
  const out = new Set();
  codes.forEach((code) => {
    out.add(code);
    Object.values(LANGUAGE_CODES).forEach((group) => {
      if (group.includes(code)) group.forEach((c) => out.add(c));
    });
  });
  return out;
};

const getJson = (url, apiKey) => new Promise((resolve, reject) => {
  const req = http.get(url, { headers: { 'X-Api-Key': apiKey }, timeout: 30000 }, (res) => {
    let body = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => { body += chunk; });
    res.on('end', () => {
      if (res.statusCode < 200 || res.statusCode > 299) {
        reject(new Error(`GET ${url} returned HTTP ${res.statusCode}: ${body.slice(0, 300)}`));
        return;
      }
      try {
        resolve(JSON.parse(body));
      } catch (err) {
        reject(new Error(`GET ${url} returned a body that is not JSON: ${err.message}`));
      }
    });
  });
  req.on('timeout', () => req.destroy(new Error(`GET ${url} timed out after 30s`)));
  req.on('error', reject);
});

const requireEnv = (name) => {
  const value = (process.env[name] || '').trim();
  if (!value) throw new Error(`${name} is not set in the tdarr container — see docker-compose.tdarr.yml`);
  return value;
};

// Returns { title, language } or null when the file belongs to no arr item.
// Errors (API down, bad key) throw instead: a file Tdarr marks "not required"
// is never looked at again, so an outage must not look like a deliberate skip.
const lookupOriginalLanguage = async (filePath) => {
  let source;
  if (filePath.startsWith('/media/movies/')) {
    source = { app: 'Radarr', url: requireEnv('TDARR_RADARR_URL'), key: requireEnv('RADARR_API_KEY'), endpoint: 'movie' };
  } else if (filePath.startsWith('/media/series/')) {
    source = { app: 'Sonarr', url: requireEnv('TDARR_SONARR_URL'), key: requireEnv('SONARR_API_KEY'), endpoint: 'series' };
  } else {
    return null;
  }
  const items = await getJson(`${source.url}/api/v3/${source.endpoint}`, source.key);
  const item = items.find((i) => i.path && filePath.startsWith(`${i.path.replace(/\/+$/, '')}/`));
  if (!item) return { app: source.app, title: null, language: null };
  return {
    app: source.app,
    title: item.title,
    language: item.originalLanguage ? item.originalLanguage.name : null,
  };
};

const streamLanguage = (stream) => ((stream.tags && stream.tags.language) || '').toLowerCase();

// Untagged and "und" tracks are kept: there is no way to know what they are.
const isUnknown = (lang) => lang === '' || lang === 'und';

const plugin = async (file, librarySettings, inputs, otherArguments) => {
  const response = {
    processFile: false,
    preset: '',
    container: `.${file.container}`,
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: false,
    infoLog: '',
  };

  if (file.fileMedium !== 'video') {
    response.infoLog += 'Not a video file, skipping.\n';
    return response;
  }

  const found = await lookupOriginalLanguage(file.file);
  if (!found) {
    response.infoLog += `${file.file} is outside /media/movies and /media/series, skipping.\n`;
    return response;
  }
  if (!found.title) {
    response.infoLog += `No ${found.app} item owns ${file.file}, skipping.\n`;
    return response;
  }
  const originalCodes = LANGUAGE_CODES[found.language];
  if (!originalCodes) {
    response.infoLog += `${found.app} reports original language "${found.language}" for ${found.title}; `
      + 'it is not in this plugin\'s language table, skipping.\n';
    return response;
  }
  response.infoLog += `${found.title}: original language ${found.language} (${found.app}).\n`;

  const subtitleLangs = (process.env.TDARR_SUBTITLE_LANGS || '')
    .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  const keepSubs = expandCodes(subtitleLangs);

  const streams = file.ffProbeData.streams || [];
  const audio = streams.filter((s) => s.codec_type === 'audio');
  const subs = streams.filter((s) => s.codec_type === 'subtitle');

  const args = [];
  let removedDefaultAudio = false;

  // A file with no track tagged in the original language is left alone: the
  // tags are wrong or the release has no original audio, and either way
  // removing everything else would leave the wrong track or none.
  const hasOriginal = audio.some((s) => originalCodes.includes(streamLanguage(s)));
  if (!hasOriginal) {
    response.infoLog += `No audio track is tagged ${found.language}; leaving audio untouched.\n`;
  } else {
    audio.forEach((s, idx) => {
      const lang = streamLanguage(s);
      if (originalCodes.includes(lang) || isUnknown(lang)) return;
      args.push(`-map -0:a:${idx}`);
      if (s.disposition && s.disposition.default === 1) removedDefaultAudio = true;
      response.infoLog += `Removing audio track ${idx} (${lang}).\n`;
    });
  }

  // An empty list means "don't touch subtitles", not "remove them all".
  if (subtitleLangs.length === 0) {
    response.infoLog += 'TDARR_SUBTITLE_LANGS is empty; leaving subtitles untouched.\n';
  } else {
    subs.forEach((s, idx) => {
      const lang = streamLanguage(s);
      if (keepSubs.has(lang) || isUnknown(lang)) return;
      args.push(`-map -0:s:${idx}`);
      response.infoLog += `Removing subtitle track ${idx} (${lang}).\n`;
    });
  }

  if (args.length === 0) {
    response.infoLog += 'Nothing to remove.\n';
    return response;
  }

  // Without this, a file whose default track was the removed dub ends up with
  // no default audio, and players pick whichever comes first.
  if (removedDefaultAudio) args.push('-disposition:a:0 default');

  response.preset = `, -map 0 ${args.join(' ')} -c copy -max_muxing_queue_size 9999`;
  response.processFile = true;
  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
