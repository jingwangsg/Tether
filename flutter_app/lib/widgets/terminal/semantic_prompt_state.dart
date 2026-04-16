enum TerminalSemanticPromptPhase { idle, prompt, input, output }

class TerminalSemanticPromptState {
  bool hasSeenSemanticPrompt = false;
  bool shellRedrawsPrompt = true;
  TerminalSemanticPromptPhase phase = TerminalSemanticPromptPhase.idle;

  bool get shouldUseResizeRecovery =>
      hasSeenSemanticPrompt && shellRedrawsPrompt;

  bool handlePrivateOsc(String code, List<String> args) {
    if (code != '133' || args.isEmpty) return false;

    hasSeenSemanticPrompt = true;

    final action = args.first;
    final options = _parseOptions(args.skip(1));
    if (action == 'A' && options.containsKey('redraw')) {
      shellRedrawsPrompt = options['redraw'] == '1';
    }

    switch (action) {
      case 'A':
      case 'P':
      case 'N':
        phase = TerminalSemanticPromptPhase.prompt;
      case 'B':
        phase = TerminalSemanticPromptPhase.input;
      case 'C':
        phase = TerminalSemanticPromptPhase.output;
      case 'D':
        phase = TerminalSemanticPromptPhase.idle;
      default:
        return false;
    }

    return true;
  }

  Map<String, String> _parseOptions(Iterable<String> parts) {
    final options = <String, String>{};
    for (final part in parts) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      options[part.substring(0, separator)] = part.substring(separator + 1);
    }
    return options;
  }
}
