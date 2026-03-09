import { SiteFooter } from "../components/site-footer";
import { DevPanel } from "../components/spacing-control";

export default function MainLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      {children}
      <SiteFooter />
      <DevPanel />
    </>
  );
}
