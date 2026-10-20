namespace EditAgents {

    public class AgentKeys : Object {
        private static Secret.Schema? _schema;

        private static Secret.Schema schema () {
            if (_schema == null)
                _schema = new Secret.Schema ("dev.sinty.edit.AgentKey", Secret.SchemaFlags.NONE,
                                             "agent", Secret.SchemaAttributeType.STRING);
            return _schema;
        }

        public static string default_variable (AgentEntry agent) {
            if (agent.key_variable != "") return agent.key_variable;
            switch (agent.id) {
                case "claude-acp": return "ANTHROPIC_API_KEY";
                case "codex-acp": return "OPENAI_API_KEY";
                case "gemini": return "GEMINI_API_KEY";
                case "github-copilot-cli": return "GH_TOKEN";
                default: return "";
            }
        }

        public static async string? lookup (string agent_id) {
            try {
                return yield Secret.password_lookup (schema (), null, "agent", agent_id);
            } catch (Error e) {
                return null;
            }
        }

        public static async void store (AgentEntry agent, string variable, string value) throws Error {
            yield Secret.password_store (schema (), Secret.COLLECTION_DEFAULT, _("Edit key for %s").printf (agent.name),
                                         variable + "=" + value, null, "agent", agent.id);
        }

        public static async void forget (string agent_id) throws Error {
            yield Secret.password_clear (schema (), null, "agent", agent_id);
        }

        public static bool valid_variable (string name) {
            if (name == "") return false;
            for (int i = 0; i < name.length; i++) {
                char c = name[i];
                if (!(c.isalnum () || c == '_') || (i == 0 && c.isdigit ())) return false;
            }
            return true;
        }
    }
}
