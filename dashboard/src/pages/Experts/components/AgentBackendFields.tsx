import type { BackendOption } from "./agentBackendForm";
import { useTranslation } from "react-i18next";

interface AgentBackendFieldsProps {
  backends: BackendOption[];
  backendsLoading: boolean;
  backendChoice: string;
  pathMappings: { path: string; backend: string }[];
  rootDirMode?: "create" | "edit";
  disabled?: boolean;
  skipHostFilesystem?: boolean;
  onAddPathMapping: () => void;
  onRemovePathMapping: (index: number) => void;
  onUpdatePathMapping: (
    index: number,
    field: "path" | "backend",
    value: string,
  ) => void;
}

/** Expert workspace access is fixed: server stores records; Worker scopes the PC. */
export default function AgentBackendFields(_props: AgentBackendFieldsProps) {
  const { t } = useTranslation();
  return (
    <div style={{ margin: "0 0 16px" }}>
      <p
        style={{
          fontSize: 13,
          color: "var(--fn-text-secondary)",
          margin: 0,
          lineHeight: 1.6,
        }}
      >
        {t("experts.pcAccessHint")}
      </p>
    </div>
  );
}
