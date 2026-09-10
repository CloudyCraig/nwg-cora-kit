// Renders the official NatWest brand mark supplied by the customer. The
// asset lives at /frontend/public/natwest-logo.png and is served verbatim
// by Vite/nginx from the SPA root, so we don't need to bundle it through
// the JS module graph.
//
// Why an <img> rather than a CSS background-image:
//   * <img alt> gives screen readers the brand name without us having to
//     hand-roll an aria label.
//   * The browser cache treats it like any other static asset and can
//     skip re-downloading on subsequent navigations.
//
// Image dimensions are 800x797 (effectively square). The component scales
// uniformly via the `height` prop; width auto-sizes to preserve aspect.

interface Props {
  /** Visual height of the mark in px. Width auto-scales to keep the aspect ratio. */
  height?: number;
  /** Optional extra class for one-off positioning (centring, margins). */
  className?: string;
}

export default function NatWestLogo({ height = 56, className }: Props) {
  return (
    <img
      src="/natwest-logo.png"
      alt="NatWest"
      width={height}
      height={height}
      className={`nw-logo${className ? ` ${className}` : ""}`}
      decoding="async"
      loading="eager"
      draggable={false}
    />
  );
}
