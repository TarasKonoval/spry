"use client"

import { LogOut } from "lucide-react"
import { useAuth } from "react-oidc-context"

import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { initials } from "@/lib/datetime"

export function UserMenu() {
  const auth = useAuth()

  if (auth.isLoading || !auth.isAuthenticated || !auth.user) {
    return null
  }

  const email = auth.user.profile.email as string | undefined
  const name = (auth.user.profile.name as string | undefined) ?? email ?? "Account"
  const label = name

  const handleSignOut = () => {
    auth.removeUser()

    const clientId = process.env.NEXT_PUBLIC_COGNITO_CLIENT_ID
    const domain = process.env.NEXT_PUBLIC_COGNITO_DOMAIN
    const logoutUri = typeof window !== "undefined" ? window.location.origin + "/" : ""

    window.location.href = `https://${domain}/logout?client_id=${clientId}&logout_uri=${logoutUri}`
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon-lg" className="rounded-full" aria-label="Account menu">
          <Avatar className="size-9">
            <AvatarFallback className="tint-violet text-xs font-semibold">
              {initials(name)}
            </AvatarFallback>
          </Avatar>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-60">
        <DropdownMenuLabel className="font-normal">
          <p className="truncate text-sm font-semibold">{label}</p>
          {email && email !== label ? (
            <p className="text-muted-foreground truncate text-xs">{email}</p>
          ) : null}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={handleSignOut}>
          <LogOut aria-hidden className="mr-2 size-4" />
          Sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
