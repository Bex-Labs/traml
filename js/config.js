// /js/config.js
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm'

// TODO: Replace these with your actual Supabase project credentials later
const SUPABASE_URL = 'https://mbwgglgvykjpsnvnvcsj.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1id2dnbGd2eWtqcHNudm52Y3NqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNDI0OTAsImV4cCI6MjA5NDcxODQ5MH0.s-P89TZqyd4FK6MKT_QKKaFH6GI73Ol5lzzlZlwGv-w';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);