"use client"

import { useQueryClient } from "@tanstack/react-query"
import { createContext, useContext, useEffect, useMemo, useRef } from "react"
import { useAuth as useOidcAuth } from "react-oidc-context"

import { syncMe } from "@/lib/api"
import { onUnauthorized } from "@/lib/auth"

export type AuthUser = {
  sub: string
  email?: string
  name?: string
}

type AuthState =
  | { status: "loading"; user: null }
  | { status: "signedOut"; user: null }
  | { status: "signedIn"; user: AuthUser }

type AuthContextValue = AuthState & {
  refresh: () => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const auth = useOidcAuth()
  const queryClient = useQueryClient()
  const syncedSub = useRef<string | null>(null)

  const status = auth.isLoading ? "loading" : auth.isAuthenticated ? "signedIn" : "signedOut"

  const user: AuthUser | null = useMemo(() => {
    if (!auth.isAuthenticated || !auth.user) return null
    return {
      sub: auth.user.profile.sub || "",
      email: auth.user.profile.email as string | undefined,
      name: auth.user.profile.name as string | undefined,
    }
  }, [auth.isAuthenticated, auth.user])

  // The API rejected the token: drop the local session, and the auth guard
  // sends the user back to the landing page.
  useEffect(() => {
    onUnauthorized(() => void auth.removeUser())
  }, [auth])

  useEffect(() => {
    if (status === "signedOut") {
      queryClient.clear()
      syncedSub.current = null
    }
  }, [status, queryClient])

  useEffect(() => {
    if (status === "signedIn" && auth.user?.id_token && user?.sub) {
      if (syncedSub.current !== user.sub) {
        syncedSub.current = user.sub
        syncMe(auth.user.id_token).catch((error) => console.warn("Profile sync failed", error))
      }
    }
  }, [status, auth.user, user])

  const refresh = async () => {
    try {
      if (auth.isAuthenticated) await auth.signinSilent()
    } catch (error) {
      console.warn("Silent renew failed", error)
    }
  }

  const signOut = async () => {
    auth.removeUser()
    const clientId = process.env.NEXT_PUBLIC_COGNITO_CLIENT_ID
    const domain = process.env.NEXT_PUBLIC_COGNITO_DOMAIN
    const logoutUri = typeof window !== "undefined" ? window.location.origin + "/" : ""
    window.location.href = `https://${domain}/logout?client_id=${clientId}&logout_uri=${logoutUri}`
  }

  const value = useMemo(() => ({
    status,
    user,
    refresh,
    signOut
  }) as AuthContextValue, [status, user, refresh, signOut])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) throw new Error("useAuth must be used inside <AuthProvider>")
  return context
}
