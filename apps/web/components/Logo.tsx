/**
 * Meesam wordmark (bilingual, from the brand files carried by the Pilot Prototype).
 * `tone="auto"` follows the colour scheme: ink on light, reversed on dark. `tone="reversed"` is for the
 * dark top bar in both schemes.
 */
export function Logo({ tone = "auto", height = 24, className = "" }: { tone?: "auto" | "ink" | "reversed"; height?: number; className?: string }) {
  const alt = "ميسم Meesam";
  if (tone !== "auto") return <img className={`ms-logo ${className}`} src={`/brand/meesam-${tone}.png`} alt={alt} height={height} />;
  return (
    <picture className={className}>
      <source srcSet="/brand/meesam-reversed.png" media="(prefers-color-scheme: dark)" />
      <img className="ms-logo" src="/brand/meesam-ink.png" alt={alt} height={height} />
    </picture>
  );
}
