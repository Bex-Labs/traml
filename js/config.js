// /js/config.js
import { createClient } from './vendor/supabase-js-2.118.0.js'

// Hosted application configuration. Loopback browser origins use the local stack below.
const SUPABASE_URL = 'https://mbwgglgvykjpsnvnvcsj.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1id2dnbGd2eWtqcHNudm52Y3NqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNDI0OTAsImV4cCI6MjA5NDcxODQ5MH0.s-P89TZqyd4FK6MKT_QKKaFH6GI73Ol5lzzlZlwGv-w';

if (window.location.protocol === 'file:') {
    throw new Error('Serve CoreAML over HTTP instead of opening its HTML files directly.');
}

const isLocal = ['localhost', '127.0.0.1', '[::1]', '::1'].includes(window.location.hostname);
const apiUrl = isLocal ? 'http://127.0.0.1:55321' : SUPABASE_URL;
const publicKey = isLocal ? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH' : SUPABASE_ANON_KEY;

export const supabase = createClient(apiUrl, publicKey);
