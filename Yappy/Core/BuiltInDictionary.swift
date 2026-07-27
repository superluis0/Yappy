//
//  BuiltInDictionary.swift
//  Yappy
//

import Foundation

/// A curated starter set of developer / tech terms, seeded once into the user's
/// dictionary so they transcribe correctly out of the box. Each term carries the
/// common mishearings as aliases; `DictionaryReplacer` rewrites those back to the
/// canonical spelling.
///
/// Aliases are chosen conservatively: multi-word phonetic splits ("super base")
/// and clearly non-English misspellings ("kubernetis"), never real words or
/// names ("jason", "cloud", "sequel"), because the replacer matches whole words
/// case-insensitively and would otherwise rewrite legitimate text.
enum BuiltInDictionary {
    static let terms: [DictionaryTerm] = [
        term("Supabase", ["super base", "supa base", "superbase"]),
        term("Vercel", ["versel", "ver cell", "vercell"]),
        term("Cloudflare", ["cloud flare", "cloudflair"]),
        term("Kubernetes", ["kubernetis", "kuberneties"]),
        term("PostgreSQL", ["postgres ql", "postgre sql", "postgres sql"]),
        term("GraphQL", ["graph ql", "graphq l"]),
        term("TypeScript", ["type script"]),
        term("JavaScript", ["java script"]),
        term("Node.js", ["node js", "nodejs"]),
        term("Next.js", ["next js", "nextjs"]),
        term("Tailwind", ["tail wind"]),
        term("Redis", ["reddis"]),
        term("nginx", ["engine x", "engine ex"]),
        term("GitHub", ["git hub"]),
        term("GitLab", ["git lab"]),
        term("OAuth", ["o auth", "oh auth"]),
        term("Anthropic", ["anthropik", "and tropic"]),
        term("OpenAI", ["open ai", "open eye"]),
        term("Xcode", ["x code"]),
        term("JSON", ["jay son"]),
        term("YAML", ["yamel", "yammel"]),
        term("MongoDB", ["mongo db", "mongo d b"]),
        term("DynamoDB", ["dynamo db"]),
        term("Terraform", ["terra form"]),
        term("FastAPI", ["fast api"]),
        term("Vite", ["veet"]),
        term("Twilio", ["twillio"]),
        term("Firebase", ["fire base"]),
        term("Heroku", ["heroko", "her oku"]),
        term("DigitalOcean", ["digital ocean"]),
        term("Netlify", ["net lify", "netliffy"]),
        term("Datadog", ["data dog"]),
        term("Grafana", ["graphana", "gra fana"]),
        term("WebSocket", ["web socket"]),
        term("localhost", ["local host"]),
        term("Kotlin", ["cotlin"]),
        term("Django", ["jango"])
    ]

    private static func term(_ text: String, _ aliases: [String]) -> DictionaryTerm {
        DictionaryTerm(text: text, aliases: aliases, isBuiltIn: true)
    }
}
