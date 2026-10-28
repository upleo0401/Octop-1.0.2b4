import { Button, Modal } from "antd";
import { useTranslation } from "react-i18next";

import styles from "./ForgotPasswordModal.module.less";

interface Props {
  open: boolean;
  onClose: () => void;
}

export default function ForgotPasswordModal({ open, onClose }: Props) {
  const { t } = useTranslation();

  return (
    <Modal
      open={open}
      title={t("login.forgotPasswordTitle", "Reset password")}
      onCancel={onClose}
      footer={
        <Button type="primary" onClick={onClose}>
          {t("login.forgotPasswordOk", "Got it")}
        </Button>
      }
      width={520}
      centered
      destroyOnHidden
    >
      <div className={styles.body} data-testid="login-forgot-password">
        <p className={styles.help}>
          {t(
            "login.forgotPasswordHelp",
            "Ask an administrator to reset your password on the Users page.",
          )}
        </p>
        <p className={styles.hint}>
          {t(
            "login.forgotPasswordHint",
            "New password: at least 8 characters with letters and digits.",
          )}
        </p>
      </div>
    </Modal>
  );
}
