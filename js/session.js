import { supabase } from './config.js';

// 30 Minutes in milliseconds (30 * 60 * 1000)
const SESSION_TIMEOUT_MS = 1800000; 
let timeoutId;

/**
 * Resets the inactivity timer every time the user interacts with the page.
 */
function resetTimer() {
    clearTimeout(timeoutId);
    timeoutId = setTimeout(triggerAutoLogout, SESSION_TIMEOUT_MS);
}

/**
 * Executes when the timer hits zero. Destroys the session on the server.
 */
async function triggerAutoLogout() {
    console.warn("Session expired due to inactivity. Enforcing auto-logout.");
    
    // The standard signOut() invalidates the current session on the Supabase server
    await supabase.auth.signOut();
    
    // Redirect to login page with an optional URL parameter to show a message
    window.location.href = 'login.html?expired=true';
}

/**
 * Global Logout: Destroys ALL active sessions for this user across all devices.
 * You will attach this to the "Log out of all sessions" button in the UI.
 */
export async function terminateAllSessions() {
    console.log("Initiating global session termination...");
    
    // The { scope: 'global' } parameter specifically targets all devices
    await supabase.auth.signOut({ scope: 'global' });
    
    window.location.href = 'login.html';
}

// Attach the watchdog to all major physical interactions
const interactionEvents = ['mousemove', 'keydown', 'click', 'scroll', 'touchstart'];

interactionEvents.forEach(event => {
    document.addEventListener(event, resetTimer, { passive: true });
});

// Start the timer the moment the script loads
resetTimer();