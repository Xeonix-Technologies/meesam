/**
 * Whether new accounts can be created in this environment (Founder ruling 23 Nov 2026: production keeps sign-up
 * closed until launch). A configuration value, SIGNUP: "open" opens it; unset or anything else keeps it closed, so a
 * new environment never opens by oversight. Signing in, invitations to an existing account and staff logins are not
 * affected.
 */
export const signupOpen = (): boolean => (process.env.SIGNUP ?? "").trim().toLowerCase() === "open";
