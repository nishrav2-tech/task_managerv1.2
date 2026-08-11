/**
 * Utopian CRM — Supabase configuration
 *
 * SETUP:
 *   1. Copy this file to `config.js` (which is gitignored)
 *   2. Paste your Supabase project URL + anon key below
 *   3. Refresh the app — the sidebar badge will switch from "Local" to "Supabase"
 *
 * Find these in your Supabase dashboard:
 *   Project Settings → API → Project URL + anon/public key
 *
 * The anon key is safe to expose publicly — access is controlled by the
 * Row Level Security policies in schema.sql. If you need stricter access,
 * enable Supabase Auth and update the RLS policies.
 */

window.CRM_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co',
  supabaseKey: 'YOUR-ANON-KEY-HERE'
};
