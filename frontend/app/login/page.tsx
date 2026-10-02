"use client";

import { useAuth } from "react-oidc-context";
import { useEffect } from "react";

export default function LoginPage() {
  const auth = useAuth();

  useEffect(() => {
    if (!auth.isAuthenticated && !auth.activeNavigator) {
      auth.signinRedirect();
    }
  }, [auth]);

  return <div className="p-8 text-center">Redirecting to secure login...</div>;
}
