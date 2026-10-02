import { User } from "oidc-client-ts"
import type { AuthProviderProps } from "react-oidc-context"

const userPoolId = process.env.NEXT_PUBLIC_COGNITO_USER_POOL_ID ?? ""
const clientId = process.env.NEXT_PUBLIC_COGNITO_CLIENT_ID ?? ""
// Pool IDs look like "us-east-1_AbC123": the region is the part before the underscore.
const region = userPoolId.split("_")[0]

export const isAuthConfigured = Boolean(userPoolId && clientId)

/** Settings for react-oidc-context: Cognito's managed login, redirecting back to "/". */
export const oidcConfig: AuthProviderProps = {
  authority: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`,
  client_id: clientId,
  // Only read in the browser; the server render never starts a sign-in.
  redirect_uri: typeof window !== "undefined" ? `${window.location.origin}/` : "",
  response_type: "code",
  scope: "openid email profile",
  // Drop ?code=…&state=… from the address bar once the sign-in is complete.
  onSigninCallback: () => {
    window.history.replaceState({}, document.title, window.location.pathname)
  },
}

/** Where oidc-client-ts keeps the signed-in user (its default: sessionStorage). */
const storageKey = `oidc.user:${oidcConfig.authority}:${oidcConfig.client_id}`

/**
 * The current access token, kept fresh by oidc-client-ts's silent renew. Read
 * from storage rather than React state so the API client can call it anywhere.
 */
export function getAccessToken(): string | null {
  if (!isAuthConfigured || typeof window === "undefined") return null
  const stored = window.sessionStorage.getItem(storageKey)
  if (!stored) return null
  const user = User.fromStorageString(stored)
  return user.expired ? null : user.access_token
}

let unauthorizedHandler: () => void = () => {}

/** Registered by the auth provider: what to do when the API rejects the session. */
export function onUnauthorized(handler: () => void) {
  unauthorizedHandler = handler
}

export function handleUnauthorized() {
  unauthorizedHandler()
}
