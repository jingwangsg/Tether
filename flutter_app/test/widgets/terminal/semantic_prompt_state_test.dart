import 'package:flutter_test/flutter_test.dart';
import 'package:tether/widgets/terminal/semantic_prompt_state.dart';

void main() {
  group('TerminalSemanticPromptState', () {
    test('tracks OSC 133 phase transitions', () {
      final state = TerminalSemanticPromptState();

      expect(state.hasSeenSemanticPrompt, isFalse);
      expect(state.phase, TerminalSemanticPromptPhase.idle);

      state.handlePrivateOsc('133', ['A']);
      expect(state.hasSeenSemanticPrompt, isTrue);
      expect(state.phase, TerminalSemanticPromptPhase.prompt);

      state.handlePrivateOsc('133', ['B']);
      expect(state.phase, TerminalSemanticPromptPhase.input);

      state.handlePrivateOsc('133', ['C']);
      expect(state.phase, TerminalSemanticPromptPhase.output);

      state.handlePrivateOsc('133', ['D', '0']);
      expect(state.phase, TerminalSemanticPromptPhase.idle);
    });

    test('tracks redraw preference from OSC 133 A', () {
      final state = TerminalSemanticPromptState();

      expect(state.shellRedrawsPrompt, isTrue);
      expect(state.shouldUseResizeRecovery, isFalse);

      state.handlePrivateOsc('133', ['A', 'redraw=0']);
      expect(state.shellRedrawsPrompt, isFalse);
      expect(state.shouldUseResizeRecovery, isFalse);

      state.handlePrivateOsc('133', ['A', 'redraw=1']);
      expect(state.shellRedrawsPrompt, isTrue);
      expect(state.shouldUseResizeRecovery, isTrue);

      state.handlePrivateOsc('133', ['D', '0']);
      expect(state.shouldUseResizeRecovery, isTrue);
    });
  });
}
