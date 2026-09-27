import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://blau.app"),
  alternates: { canonical: "/stream" },
  title: "Blau Stream",
  description: "Share your screen. Tell your story. Stream from your Apple devices.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
