export function Callout({
  type = "info",
  children,
}: {
  type?: "info" | "warn";
  children: React.ReactNode;
}) {
  const style =
    type === "warn"
      ? undefined
      : {
          borderLeftColor: "var(--accent)",
          background: "rgba(var(--accent-rgb), 0.05)",
        } as const;
  const className =
    type === "warn"
      ? "border-l-amber-500 bg-amber-500/5"
      : "";

  return (
    <div
      className={`${className} border-l-2 px-4 py-3 mb-4 rounded-r-lg text-[14px] text-muted leading-relaxed`}
      style={style}
    >
      {children}
    </div>
  );
}
