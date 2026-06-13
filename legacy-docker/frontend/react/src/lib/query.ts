import { QueryClient } from "@tanstack/react-query";

/*
 * Single shared QueryClient. Created once per mount; the host SPA may mount
 * and unmount many React views over the page lifetime, but we keep one client
 * across mounts so cached data survives navigation.
 */
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 5 * 60_000,
      refetchOnWindowFocus: false,
      retry: 1,
    },
    mutations: {
      retry: 0,
    },
  },
});
