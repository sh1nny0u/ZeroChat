"""Run on the server: python -m tools.reset_admin (never a remote endpoint)."""
from getpass import getpass
from services.auth_service import initialize, reset_password


def main():
    initialize()
    password = getpass("New administrator password (6-14 characters): ")
    if password != getpass("Confirm password: "):
        raise SystemExit("Passwords differ; no changes made")
    reset_password(password)
    print("Password reset. All device sessions have been revoked.")


if __name__ == "__main__":
    main()
