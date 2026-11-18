import type { NextConfig } from "next";

// cacheComponents kapalı: her sayfa oturumdaki kullanıcıya ve rolüne göre
// her istekte yeniden üretilir. Yetkiyi zaten veritabanı (RLS) belirliyor.
const nextConfig: NextConfig = {
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
