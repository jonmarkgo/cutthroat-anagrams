// Cutthroat Anagrams Game Client
import { Socket } from "phoenix";

class CutthroatAnagramsGame {
  constructor() {
    this.socket = null;
    this.channel = null;
    this.playerId = null;
    this.gameId = null;
    this.playerName = null;
    this.isListening = false;
    this.currentRecognition = null;
    this.gameState = null;
    this.pendingClaims = new Map(); // Track simultaneous claims
    
    // Speech recognition setup
    this.recognition = null;
    this.audioContext = null;
    this.micStream = null;
    
    this.initializeEventHandlers();
    this.updateGameSetupState();
  }

  initializeEventHandlers() {
    // Setup screen handlers
    document.getElementById('create-game-btn').onclick = () => this.createGame();
    document.getElementById('join-game-btn').onclick = () => this.joinGame();
    
    // Game screen handlers
    document.getElementById('flip-tile-btn').onclick = () => this.flipTile();
    document.getElementById('mic-toggle').onclick = () => this.toggleMicrophone();
    document.getElementById('copy-code-btn').onclick = () => this.copyGameCode();
    document.getElementById('manual-claim-btn').onclick = () => this.manualClaimWord();
    
    // Modal handlers
    document.getElementById('confirm-word-btn').onclick = () => this.confirmWord();
    document.getElementById('cancel-word-btn').onclick = () => this.cancelWord();
    document.getElementById('flip-coin-btn').onclick = () => this.flipCoin();
    document.getElementById('new-game-btn').onclick = () => this.newGame();
    
    // Enter key handlers
    document.getElementById('player-name').onkeypress = (e) => {
      if (e.key === 'Enter') this.createGame();
    };
    document.getElementById('game-code').onkeypress = (e) => {
      if (e.key === 'Enter') this.joinGame();
    };
    document.getElementById('word-input').onkeypress = (e) => {
      if (e.key === 'Enter') this.confirmWord();
    };
    document.getElementById('manual-word-input').onkeypress = (e) => {
      if (e.key === 'Enter') this.manualClaimWord();
    };
    
    // Real-time word update as user types
    document.getElementById('word-input').oninput = (e) => {
      this.updateWordBeingConfirmed(e.target.value);
      this.updateStealDetails(e.target.value);
    };
    
    // Name input validation
    document.getElementById('player-name').oninput = () => this.updateGameSetupState();
  }

  generateGameId() {
    return Math.random().toString(36).substring(2, 8).toUpperCase();
  }

  updateGameSetupState() {
    const playerName = document.getElementById('player-name').value.trim();
    const createBtn = document.getElementById('create-game-btn');
    const joinBtn = document.getElementById('join-game-btn');
    
    const hasName = playerName.length > 0;
    
    // Enable/disable buttons based on name input
    createBtn.disabled = !hasName;
    joinBtn.disabled = !hasName;
    
    // Update button styling
    if (hasName) {
      createBtn.classList.remove('btn-disabled');
      joinBtn.classList.remove('btn-disabled');
    } else {
      createBtn.classList.add('btn-disabled');
      joinBtn.classList.add('btn-disabled');
    }
  }

  createGame() {
    const playerName = document.getElementById('player-name').value.trim();
    if (!playerName) {
      alert('Please enter your name first');
      document.getElementById('player-name').focus();
      return;
    }
    
    // Get minimum word length from UI
    const minWordLength = parseInt(document.getElementById('min-word-length').value);
    
    this.gameId = this.generateGameId();
    this.playerName = playerName;
    this.minWordLength = minWordLength; // Store for use when connecting
    this.connectToGame();
  }

  joinGame() {
    const playerName = document.getElementById('player-name').value.trim();
    const gameCode = document.getElementById('game-code').value.trim().toUpperCase();
    
    if (!playerName) {
      alert('Please enter your name first');
      document.getElementById('player-name').focus();
      return;
    }
    
    if (!gameCode) {
      alert('Please enter a game code');
      document.getElementById('game-code').focus();
      return;
    }
    
    this.gameId = gameCode;
    this.playerName = playerName;
    this.connectToGame();
  }

  connectToGame() {
    // Initialize Phoenix Socket
    this.socket = new Socket("/socket", {
      params: {token: ""}
    });
    
    this.socket.connect();
    
    // Prepare channel join parameters
    const channelParams = {
      player_name: this.playerName
    };
    
    // Add min_word_length if this is a new game (i.e., we have it stored)
    if (this.minWordLength) {
      channelParams.min_word_length = this.minWordLength;
    }
    
    // Join game channel
    this.channel = this.socket.channel(`game:${this.gameId}`, channelParams);
    
    this.setupChannelHandlers();
    
    this.channel.join()
      .receive("ok", (response) => {
        console.log("Joined game successfully", response);
        this.playerId = response.player_id;
        this.gameState = response.game_state;
        this.switchToGameScreen();
        this.updateGameUI();
      })
      .receive("error", (resp) => {
        console.log("Unable to join", resp);
        alert(`Failed to join game: ${resp.reason}`);
      });
  }

  setupChannelHandlers() {
    // Player joined/left
    this.channel.on("player_joined", (payload) => {
      console.log("Player joined:", payload);
      this.gameState = payload.game_state;
      this.updateGameUI();
      this.showNotification(`${payload.player_name} joined the game`);
    });
    
    this.channel.on("player_left", (payload) => {
      console.log("Player left:", payload);
      this.showNotification(`${payload.player_name} left the game`);
    });
    
    // Tile flipped
    this.channel.on("tile_flipped", (payload) => {
      console.log("Tile flipped:", payload);
      this.gameState = payload.game_state;
      this.updateGameUI();
      this.animateNewTile(payload.tile);
    });
    
    // Voice claim detected
    this.channel.on("voice_claim_detected", (payload) => {
      console.log("Voice claim detected:", payload);
      this.handleVoiceClaim(payload);
    });
    
    // Word claimed
    this.channel.on("word_claimed", (payload) => {
      console.log("Word claimed:", payload);
      this.gameState = payload.game_state;
      this.updateGameUI();
      this.showWordClaimNotification(payload);
    });
    
    // Word stolen
    this.channel.on("word_stolen", (payload) => {
      console.log("Word stolen:", payload);
      this.gameState = payload.game_state;
      this.updateGameUI();
      this.showWordStealNotification(payload);
      
      // Close confirmation pause modal for other players
      this.updateModalToClaimSuccess(payload);
    });
    
    // Word being confirmed (during pause)
    this.channel.on("word_being_confirmed", (payload) => {
      console.log("Word being confirmed:", payload);
      // Show pause modal to opposing players
      if (payload.player_name !== this.playerName) {
        this.showWordBeingConfirmedModal(payload);
      }
    });
    
    // Claim confirmed/rejected
    this.channel.on("claim_confirmed", (payload) => {
      console.log("Claim confirmed:", payload);
      this.gameState = payload.game_state;
      this.updateGameUI();
      this.pendingClaims.delete(payload.timestamp);
      
      // Update the modal to show claim success
      this.updateModalToClaimSuccess(payload);
    });
    
    this.channel.on("claim_rejected", (payload) => {
      console.log("Claim rejected:", payload);
      
      // Show user-friendly error messages
      let message;
      switch(payload.reason) {
        case 'not_in_dictionary':
          message = `"${payload.word.toUpperCase()}" is not in the dictionary`;
          break;
        case 'invalid_tiles':
          message = `"${payload.word.toUpperCase()}" cannot be formed from available tiles`;
          break;
        case 'word_too_short':
          message = `"${payload.word.toUpperCase()}" is too short (minimum ${this.gameState.min_word_length} letters)`;
          break;
        case 'must_add_letter':
          message = `You must add at least one letter from the tile pool to steal a word!`;
          break;
        case 'invalid_transformation':
          message = `"${payload.word.toUpperCase()}" is just a simple variation (like adding a suffix). You must rearrange letters to steal!`;
          break;
        case 'invalid_steal':
          message = `Cannot steal to form "${payload.word.toUpperCase()}" - check available letters`;
          break;
        default:
          message = `Word "${payload.word.toUpperCase()}" was rejected: ${payload.reason}`;
      }
      
      this.showNotification(message, 'error');
      this.pendingClaims.delete(payload.timestamp);
      
      // Close the pause modal for other players when claim is rejected
      this.updateModalToClaimRejection(payload);
    });
    
    // Tie resolution
    this.channel.on("tie_resolved", (payload) => {
      console.log("Tie resolved:", payload);
      this.showCoinFlipResult(payload);
    });
    
    // Game ended
    this.channel.on("game_ended", (payload) => {
      console.log("Game ended:", payload);
      this.showEndScreen(payload);
    });
  }

  switchToGameScreen() {
    document.getElementById('setup-screen').classList.add('hidden');
    document.getElementById('game-screen').classList.remove('hidden');
    document.getElementById('player-name-display').textContent = this.playerName;
    document.getElementById('code-display').textContent = this.gameId;
    
    // Display minimum word length from game state
    if (this.gameState && this.gameState.min_word_length) {
      document.getElementById('min-length-display').textContent = this.gameState.min_word_length;
    }
  }

  updateGameUI() {
    if (!this.gameState) return;
    
    // Update flipped tiles
    const flippedContainer = document.getElementById('flipped-letters');
    flippedContainer.innerHTML = this.gameState.flipped_tiles.map(tile => 
      `<div class="badge badge-lg badge-primary font-mono">${tile}</div>`
    ).join('');
    
    // Update remaining count
    document.getElementById('remaining-count').textContent = this.gameState.tiles_remaining;
    
    // Update players
    this.updatePlayersDisplay();
    
    // Update flip button state
    const flipBtn = document.getElementById('flip-tile-btn');
    const isMyTurn = this.gameState.current_turn === this.playerId;
    flipBtn.disabled = !isMyTurn || this.gameState.status !== 'playing';
    flipBtn.className = `btn ${isMyTurn ? 'btn-primary' : 'btn-disabled'}`;
    
    // Update game status
    const statusEl = document.getElementById('game-status');
    if (this.gameState.status === 'waiting') {
      statusEl.textContent = `Waiting for players... (${this.gameState.players.length}/2)`;
    } else if (this.gameState.status === 'playing') {
      const currentPlayer = this.gameState.players.find(p => p.id === this.gameState.current_turn);
      statusEl.textContent = `${currentPlayer?.name || 'Unknown'}'s turn to flip`;
    }
  }

  updatePlayersDisplay() {
    const container = document.getElementById('players-container');
    container.innerHTML = this.gameState.players.map(player => {
      const isCurrentPlayer = player.id === this.playerId;
      
      // Create words display with proper spacing
      const words = player.words.map((wordObj, index) => {
        // Color code by word length to show value
        const lengthClass = wordObj.letters.length >= 7 ? 'border-success' :
                           wordObj.letters.length >= 5 ? 'border-warning' : 
                           'border-info';
        
        const stealableHint = isCurrentPlayer ? '' : 
          ' hover:shadow-lg hover:scale-105 transition-all cursor-pointer';
        
        // Create individual letter tiles for each word
        const letterTiles = wordObj.letters.map(letter => 
          `<div class="badge badge-sm badge-primary font-mono text-xs">${letter}</div>`
        ).join('');
        
        return `<div class="card bg-base-100 border-2 ${lengthClass} ${stealableHint} p-2 inline-block min-w-fit" 
                     title="Word: ${wordObj.word.toUpperCase()} (${wordObj.letters.length} letters)${isCurrentPlayer ? '' : ' - Click to steal!'}"
                     data-word="${wordObj.word}" 
                     data-word-index="${index}"
                     data-player-id="${player.id}"
                     onclick="${isCurrentPlayer ? '' : 'game.attemptSteal(this)'}">
                  <div class="flex gap-1 justify-center">
                    ${letterTiles}
                  </div>
                </div>`;
      }).join('');
      
      return `
        <div class="card bg-base-100 shadow-sm ${isCurrentPlayer ? 'ring-2 ring-primary' : ''}">
          <div class="card-body p-4">
            <!-- Player Info Header -->
            <div class="flex justify-between items-center mb-3">
              <div class="flex items-center gap-3">
                <div>
                  <h4 class="font-bold text-lg ${isCurrentPlayer ? 'text-primary' : ''}">${player.name}</h4>
                  <div class="text-sm text-base-content/70">
                    <span class="font-semibold">${player.score}</span> points • 
                    <span class="font-semibold">${player.words.length}</span> word${player.words.length !== 1 ? 's' : ''}
                  </div>
                </div>
                ${isCurrentPlayer ? '<div class="badge badge-primary">You</div>' : ''}
              </div>
              ${this.gameState.current_turn === player.id ? '<div class="badge badge-secondary animate-pulse">Turn</div>' : ''}
            </div>
            
            <!-- Words Display Area -->
            ${player.words.length > 0 ? `
              <div class="border-t border-base-300 pt-3">
                <div class="text-xs font-semibold text-base-content/60 mb-2 uppercase tracking-wide">Claimed Words</div>
                <div class="flex flex-wrap gap-2 max-h-48 overflow-y-auto p-3 bg-base-50 rounded-lg border border-base-200">
                  ${words}
                </div>
              </div>
            ` : `
              <div class="border-t border-base-300 pt-3">
                <div class="text-center text-base-content/50 italic py-2">No words claimed yet</div>
              </div>
            `}
          </div>
        </div>
      `;
    }).join('');
  }

  animateNewTile(tile) {
    // Add animation for new tile
    const flippedContainer = document.getElementById('flipped-letters');
    const newTile = flippedContainer.lastElementChild;
    if (newTile) {
      newTile.classList.add('animate-bounce');
      setTimeout(() => newTile.classList.remove('animate-bounce'), 1000);
    }
  }

  flipTile() {
    this.channel.push("flip_tile", {})
      .receive("error", (resp) => {
        console.error("Flip tile error:", resp);
        alert(`Cannot flip tile: ${resp.reason}`);
      });
  }

  // Speech Recognition Implementation
  async toggleMicrophone() {
    const micBtn = document.getElementById('mic-toggle');
    
    if (!this.isListening) {
      try {
        await this.startListening();
        micBtn.textContent = '🔴';
        micBtn.classList.remove('btn-primary');
        micBtn.classList.add('btn-error');
        this.isListening = true;
      } catch (error) {
        console.error('Failed to start microphone:', error);
        alert('Failed to access microphone. Please check permissions.');
      }
    } else {
      this.stopListening();
      micBtn.textContent = '🎤';
      micBtn.classList.remove('btn-error');
      micBtn.classList.add('btn-primary');
      this.isListening = false;
    }
  }

  async startListening() {
    // Check if browser supports speech recognition
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      throw new Error('Speech recognition not supported in this browser');
    }

    // Setup microphone with optimized audio settings for fast detection
    this.micStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: 22050, // Higher sample rate for better detection
        echoCancellation: true,
        noiseSuppression: false, // Disable to reduce processing delay
        autoGainControl: true,
        latency: 0.01 // Minimum latency for fast detection
      }
    });

    // Initialize speech recognition with optimized settings
    this.recognition = new SpeechRecognition();
    this.recognition.continuous = true;
    this.recognition.interimResults = false; // Disable interim results for better performance
    this.recognition.lang = 'en-US';
    this.recognition.maxAlternatives = 1; // Only get the best result
    this.recognition.serviceURI = null; // Use default service for fastest response

    this.recognition.onresult = (event) => {
      // Process only the latest final result for performance
      const lastResult = event.results[event.results.length - 1];
      if (lastResult.isFinal) {
        const transcript = lastResult[0].transcript;
        const confidence = lastResult[0].confidence || 0.5; // Default confidence if not available
        
        // Check if this looks like a word claim (single word, reasonable confidence)
        const word = transcript.trim().toLowerCase();
        if (word.length >= this.gameState.min_word_length && 
            confidence > 0.3 && // Lower confidence threshold for fuzzy matching
            /^[a-zA-Z]+$/.test(word)) {
          
          // First try exact match from flipped tiles (fast)
          if (this.canFormWordFromTiles(word, this.gameState.flipped_tiles)) {
            this.handleSpeechWord(word, confidence);
          } else {
            // Check if word can be formed by stealing from claimed words
            const stealingPossible = this.canFormWordByStealingOrClaiming(word);
            if (stealingPossible) {
              this.handleSpeechWord(word, confidence);
            } else {
              // Try fuzzy matching if exact match fails (slower)
              const bestMatch = this.findBestWordMatch(word, this.gameState.flipped_tiles);
              const bestMatchStealing = bestMatch ? this.canFormWordByStealingOrClaiming(bestMatch) : false;
              
              if (bestMatch && (this.canFormWordFromTiles(bestMatch, this.gameState.flipped_tiles) || bestMatchStealing)) {
                this.handleSpeechWord(bestMatch, confidence);
              } else {
                // Show feedback about what words are possible (don't do this on every speech)
                console.log(`No match found for: ${word}`);
              }
            }
          }
        }
      }
    };

    this.recognition.onerror = (event) => {
      console.error('Speech recognition error:', event.error);
      if (event.error === 'not-allowed') {
        alert('Microphone permission denied. Please enable microphone access.');
      }
    };

    this.recognition.onend = () => {
      // Restart if still listening
      if (this.isListening) {
        setTimeout(() => {
          if (this.isListening) {
            this.recognition.start();
          }
        }, 100);
      }
    };

    this.recognition.start();
  }

  stopListening() {
    if (this.recognition) {
      this.recognition.stop();
      this.recognition = null;
    }
    if (this.micStream) {
      this.micStream.getTracks().forEach(track => track.stop());
      this.micStream = null;
    }
    this.hideInterimSpeech();
  }

  handleSpeechWord(word, confidence) {
    const timestamp = Date.now();
    
    // Show confirmation modal with timer
    this.showWordConfirmationModal(word, timestamp);
  }

  showWordConfirmationModal(word, timestamp) {
    const modal = document.getElementById('word-confirmation-modal');
    document.getElementById('recognized-word').textContent = word.toUpperCase();
    document.getElementById('word-input').value = word;
    
    // Store timestamp for confirmation
    modal.dataset.timestamp = timestamp;
    modal.dataset.word = word;
    
    // Check if this is a steal and show details
    const stealDetails = document.getElementById('steal-details');
    const canFormFromTiles = this.canFormWordFromTiles(word, this.gameState.flipped_tiles);
    
    if (!canFormFromTiles) {
      // This is a steal - figure out what's being stolen
      const stealingInfo = this.determineStealingStrategy(word);
      
      if (stealingInfo) {
        stealDetails.classList.remove('hidden');
        
        // Show who we're stealing from
        const stealFromInfo = document.getElementById('steal-from-info');
        stealFromInfo.innerHTML = '';
        
        Object.entries(stealingInfo).forEach(([playerId, wordIndices]) => {
          const player = this.gameState.players.find(p => p.id === playerId);
          if (player) {
            wordIndices.forEach(index => {
              const stolenWord = player.words[index];
              const wordEl = document.createElement('div');
              wordEl.className = 'badge badge-warning gap-2 mr-2 mb-1';
              wordEl.innerHTML = `<span class="font-bold">${stolenWord.word.toUpperCase()}</span> from ${player.name}`;
              stealFromInfo.appendChild(wordEl);
            });
          }
        });
        
        // Calculate and show new letters being added
        const allStolenLetters = [];
        Object.entries(stealingInfo).forEach(([playerId, wordIndices]) => {
          const player = this.gameState.players.find(p => p.id === playerId);
          if (player) {
            wordIndices.forEach(index => {
              const stolenWord = player.words[index];
              allStolenLetters.push(...stolenWord.letters);
            });
          }
        });
        
        const wordLetters = word.toUpperCase().split('');
        const newLetters = [...wordLetters];
        
        // Remove stolen letters from new letters to find what's being added
        allStolenLetters.forEach(letter => {
          const index = newLetters.indexOf(letter);
          if (index > -1) {
            newLetters.splice(index, 1);
          }
        });
        
        // Display new letters
        const newLettersEl = document.getElementById('steal-new-letters');
        newLettersEl.innerHTML = '';
        
        if (newLetters.length > 0) {
          newLetters.forEach(letter => {
            const letterEl = document.createElement('div');
            letterEl.className = 'badge badge-primary badge-lg';
            letterEl.textContent = letter;
            newLettersEl.appendChild(letterEl);
          });
        } else {
          newLettersEl.innerHTML = '<span class="text-sm text-base-content/70">None (rearranging only)</span>';
        }
      } else {
        stealDetails.classList.add('hidden');
      }
    } else {
      // Regular claim from tiles
      stealDetails.classList.add('hidden');
    }
    
    // Show pause notification to other players immediately when modal appears
    // Note: This shows the originally detected word, which might be edited before confirmation
    this.channel.push("word_being_confirmed", {
      word: word,
      timestamp: timestamp,
      player_name: this.playerName
    });
    
    modal.classList.add('modal-open');
    
    // Start countdown timer
    let timeLeft = 5;
    const timerEl = document.getElementById('confirmation-timer');
    timerEl.textContent = timeLeft;
    
    const countdownInterval = setInterval(() => {
      timeLeft--;
      timerEl.textContent = timeLeft;
      
      if (timeLeft <= 0) {
        clearInterval(countdownInterval);
        if (modal.classList.contains('modal-open')) {
          this.confirmWord();
        }
      }
    }, 1000);
    
    // Store interval ID to clear it if modal is closed early
    modal.dataset.countdownInterval = countdownInterval;
  }

  confirmWord() {
    const modal = document.getElementById('word-confirmation-modal');
    const word = document.getElementById('word-input').value.trim().toLowerCase();
    const timestamp = parseInt(modal.dataset.timestamp);
    
    // Clear countdown timer
    if (modal.dataset.countdownInterval) {
      clearInterval(parseInt(modal.dataset.countdownInterval));
    }
    
    if (!word) {
      alert('Please enter a word');
      return;
    }
    
    // Update the pause modal to show the actual word being claimed (in case user edited it)
    if (word !== modal.dataset.word) {
      this.channel.push("word_being_confirmed", {
        word: word,
        timestamp: timestamp,
        player_name: this.playerName,
        updated: true // Flag to indicate this is the final word, not the initial detection
      });
    }
    
    // Determine if this is a regular claim or a steal
    if (this.canFormWordFromTiles(word, this.gameState.flipped_tiles)) {
      // Regular claim from flipped tiles
      this.channel.push("confirm_claim", {
        word: word,
        timestamp: timestamp
      });
    } else {
      // Must be stealing - figure out what to steal
      const stealingInfo = this.determineStealingStrategy(word);
      if (stealingInfo) {
        this.channel.push("steal_word", {
          word: word,
          from_players: stealingInfo,
          timestamp: timestamp
        });
      } else {
        // Fallback to regular claim if steal detection fails
        this.channel.push("confirm_claim", {
          word: word,
          timestamp: timestamp
        });
      }
    }
    
    modal.classList.remove('modal-open');
  }

  cancelWord() {
    const modal = document.getElementById('word-confirmation-modal');
    const word = modal.dataset.word;
    const timestamp = parseInt(modal.dataset.timestamp);
    
    // Clear countdown timer
    if (modal.dataset.countdownInterval) {
      clearInterval(parseInt(modal.dataset.countdownInterval));
    }
    
    modal.classList.remove('modal-open');
  }

  updateWordBeingConfirmed(newWord) {
    // Throttle updates to avoid spam - only send if word is different and has minimum length
    if (!newWord || newWord.length < 2) return;
    
    const modal = document.getElementById('word-confirmation-modal');
    const timestamp = parseInt(modal.dataset.timestamp);
    
    // Clear any existing throttle timer
    if (this.wordUpdateThrottle) {
      clearTimeout(this.wordUpdateThrottle);
    }
    
    // Send update after a short delay to avoid excessive network calls
    this.wordUpdateThrottle = setTimeout(() => {
      this.channel.push("word_being_confirmed", {
        word: newWord.trim(),
        timestamp: timestamp,
        player_name: this.playerName,
        updated: true,
        real_time: true // Flag to indicate this is a real-time update
      });
    }, 300); // 300ms delay to throttle typing
  }

  updateStealDetails(word) {
    if (!word || word.length < 2) return;
    
    word = word.toLowerCase().trim();
    const stealDetails = document.getElementById('steal-details');
    const canFormFromTiles = this.canFormWordFromTiles(word, this.gameState.flipped_tiles);
    
    if (!canFormFromTiles) {
      // This is a steal - figure out what's being stolen
      const stealingInfo = this.determineStealingStrategy(word);
      
      if (stealingInfo) {
        stealDetails.classList.remove('hidden');
        
        // Show who we're stealing from
        const stealFromInfo = document.getElementById('steal-from-info');
        stealFromInfo.innerHTML = '';
        
        Object.entries(stealingInfo).forEach(([playerId, wordIndices]) => {
          const player = this.gameState.players.find(p => p.id === playerId);
          if (player) {
            wordIndices.forEach(index => {
              const stolenWord = player.words[index];
              const wordEl = document.createElement('div');
              wordEl.className = 'badge badge-warning gap-2 mr-2 mb-1';
              wordEl.innerHTML = `<span class="font-bold">${stolenWord.word.toUpperCase()}</span> from ${player.name}`;
              stealFromInfo.appendChild(wordEl);
            });
          }
        });
        
        // Calculate and show new letters being added
        const allStolenLetters = [];
        Object.entries(stealingInfo).forEach(([playerId, wordIndices]) => {
          const player = this.gameState.players.find(p => p.id === playerId);
          if (player) {
            wordIndices.forEach(index => {
              const stolenWord = player.words[index];
              allStolenLetters.push(...stolenWord.letters);
            });
          }
        });
        
        const wordLetters = word.toUpperCase().split('');
        const newLetters = [...wordLetters];
        
        // Remove stolen letters from new letters to find what's being added
        allStolenLetters.forEach(letter => {
          const index = newLetters.indexOf(letter);
          if (index > -1) {
            newLetters.splice(index, 1);
          }
        });
        
        // Display new letters
        const newLettersEl = document.getElementById('steal-new-letters');
        newLettersEl.innerHTML = '';
        
        if (newLetters.length > 0) {
          newLetters.forEach(letter => {
            const letterEl = document.createElement('div');
            letterEl.className = 'badge badge-primary badge-lg';
            letterEl.textContent = letter;
            newLettersEl.appendChild(letterEl);
          });
        } else {
          newLettersEl.innerHTML = '<span class="text-sm text-base-content/70">None (rearranging only)</span>';
        }
      } else {
        stealDetails.classList.add('hidden');
      }
    } else {
      // Regular claim from tiles
      stealDetails.classList.add('hidden');
    }
  }

  manualClaimWord() {
    const input = document.getElementById('manual-word-input');
    const word = input.value.trim().toLowerCase();
    
    if (!word) {
      this.showNotification('Please enter a word', 'warning');
      return;
    }
    
    if (word.length < this.gameState.min_word_length) {
      this.showNotification(`Word must be at least ${this.gameState.min_word_length} letters`, 'warning');
      return;
    }
    
    // Check if word can be formed (same logic as voice recognition)
    const canFormFromTiles = this.canFormWordFromTiles(word, this.gameState.flipped_tiles);
    const canFormByStealingOrClaiming = this.canFormWordByStealingOrClaiming(word);
    
    if (!canFormFromTiles && !canFormByStealingOrClaiming) {
      this.showNotification(`"${word.toUpperCase()}" cannot be formed from available tiles`, 'warning');
      return;
    }
    
    // Clear the input
    input.value = '';
    
    // Directly claim the word without showing confirmation dialog
    const timestamp = Date.now();
    
    // Show pause notification to other players
    this.channel.push("word_being_confirmed", {
      word: word,
      timestamp: timestamp,
      player_name: this.playerName
    });
    
    // Determine if this is a regular claim or a steal
    if (this.canFormWordFromTiles(word, this.gameState.flipped_tiles)) {
      // Regular claim from flipped tiles
      this.channel.push("confirm_claim", {
        word: word,
        timestamp: timestamp
      });
    } else {
      // Must be stealing - figure out what to steal
      const stealingInfo = this.determineStealingStrategy(word);
      if (stealingInfo) {
        this.channel.push("steal_word", {
          word: word,
          from_players: stealingInfo,
          timestamp: timestamp
        });
      } else {
        this.showNotification('Unable to determine how to form this word', 'error');
      }
    }
  }

  handleVoiceClaim(payload) {
    // Don't show interrupt for our own claims
    if (payload.player_id === this.playerId) return;
    
    // Check for timing conflicts
    const existingClaim = Array.from(this.pendingClaims.values())
      .find(claim => Math.abs(claim.timestamp - payload.timestamp) < 1000);
    
    if (existingClaim) {
      // Potential tie - collect claims for coin flip
      this.handlePotentialTie([existingClaim, payload]);
    } else {
      // Store claim and show interrupt modal
      this.pendingClaims.set(payload.timestamp, payload);
      this.showInterruptModal(payload);
    }
  }

  showInterruptModal(payload) {
    const modal = document.getElementById('interrupt-modal');
    document.getElementById('claiming-player').textContent = payload.player_name;
    document.getElementById('claimed-word').textContent = payload.word.toUpperCase();
    
    let countdown = 5;
    document.getElementById('interrupt-timer').textContent = countdown;
    
    modal.classList.add('modal-open');
    
    const timer = setInterval(() => {
      countdown--;
      document.getElementById('interrupt-timer').textContent = countdown;
      
      if (countdown <= 0) {
        clearInterval(timer);
        modal.classList.remove('modal-open');
      }
    }, 1000);
    
    // Auto-close after countdown
    setTimeout(() => {
      modal.classList.remove('modal-open');
    }, 5000);
  }

  handlePotentialTie(claims) {
    // Show coin flip modal
    const modal = document.getElementById('coinflip-modal');
    const playersDiv = document.getElementById('tie-players');
    
    playersDiv.innerHTML = claims.map(claim => 
      `<div class="text-center p-2 border rounded">
        <strong>${claim.player_name}</strong><br>
        "${claim.word.toUpperCase()}"
      </div>`
    ).join('');
    
    modal.classList.add('modal-open');
  }

  flipCoin() {
    // Get current tie claims (simplified - in real implementation this would be managed by server)
    const claims = Array.from(this.pendingClaims.values());
    
    this.channel.push("resolve_tie", {
      claims: claims
    });
  }

  showCoinFlipResult(payload) {
    const modal = document.getElementById('coinflip-modal');
    const resultDiv = document.getElementById('coin-result');
    
    resultDiv.innerHTML = `
      <div class="text-success">
        🎉 ${payload.winner.player_name} wins!<br>
        Word: "${payload.winner.word.toUpperCase()}"
      </div>
    `;
    
    setTimeout(() => {
      modal.classList.remove('modal-open');
    }, 3000);
  }

  showInterimSpeech(text) {
    // Could show interim speech recognition results
    // For now, we'll skip this to avoid UI clutter
  }

  hideInterimSpeech() {
    // Hide interim speech display
  }



  showWordClaimNotification(payload) {
    const message = `${payload.player_name} claimed "${payload.word.toUpperCase()}"`;
    this.showNotification(message);
  }

  showWordBeingConfirmedModal(payload) {
    const modal = document.getElementById('interrupt-modal');
    const modalBox = document.getElementById('interrupt-modal-box');
    
    if (modal.classList.contains('modal-open') && (payload.updated || payload.real_time)) {
      // Just update the word if modal is already open and this is an update
      document.getElementById('claimed-word').textContent = payload.word.toUpperCase();
      
      // Update the message for real-time updates
      if (payload.real_time) {
        document.getElementById('pause-message').textContent = 'Game paused - word being edited...';
      }
    } else if (!modal.classList.contains('modal-open')) {
      // Set up "confirming" state only if modal isn't already open
      modalBox.className = 'modal-box bg-warning text-warning-content';
      document.getElementById('claiming-player').textContent = payload.player_name;
      document.getElementById('claim-action').textContent = 'is confirming:';
      document.getElementById('claimed-word').textContent = payload.word.toUpperCase();
      document.getElementById('pause-message').textContent = 'Game paused for confirmation...';
      
      modal.classList.add('modal-open');
    }
  }

  updateModalToClaimSuccess(payload) {
    const modal = document.getElementById('interrupt-modal');
    const modalBox = document.getElementById('interrupt-modal-box');
    
    
    if (modal.classList.contains('modal-open')) {
      // Update to "claimed" state
      modalBox.className = 'modal-box bg-success text-success-content';
      document.getElementById('claim-action').textContent = 'claimed:';
      document.getElementById('claimed-word').textContent = payload.word.toUpperCase();
      document.getElementById('pause-message').textContent = 'Word claimed successfully!';
      
      // Auto-close after showing success
      setTimeout(() => {
        modal.classList.remove('modal-open');
      }, 1500);
    } else if (payload.player_id !== this.playerId) {
      // Show brief claim notification if modal wasn't already open
      this.showWordClaimModal(payload);
    }
  }

  updateModalToClaimRejection(payload) {
    const modal = document.getElementById('interrupt-modal');
    const modalBox = document.getElementById('interrupt-modal-box');
    
    if (modal.classList.contains('modal-open')) {
      // Update to "rejected" state
      modalBox.className = 'modal-box bg-error text-error-content';
      document.getElementById('claim-action').textContent = 'failed to claim:';
      document.getElementById('pause-message').textContent = `Claim rejected: ${payload.reason || 'Invalid word'}`;
      
      // Auto-close after showing rejection
      setTimeout(() => {
        modal.classList.remove('modal-open');
      }, 2000);
    }
  }

  showWordClaimModal(payload) {
    const modal = document.getElementById('interrupt-modal');
    const modalBox = document.getElementById('interrupt-modal-box');
    
    // Set up "claimed" state for brief notification
    modalBox.className = 'modal-box bg-info text-info-content';
    document.getElementById('claiming-player').textContent = payload.player_name;
    document.getElementById('claim-action').textContent = 'claimed:';
    document.getElementById('claimed-word').textContent = payload.word.toUpperCase();
    document.getElementById('pause-message').textContent = 'Word claimed!';
    
    modal.classList.add('modal-open');
    
    // Auto-close after 1.5 seconds
    setTimeout(() => {
      modal.classList.remove('modal-open');
    }, 1500);
  }

  showWordStealNotification(payload) {
    // from_players is an object like {"player_id": [word_indices]}
    const playerIds = Object.keys(payload.from_players);
    const fromPlayerNames = playerIds.map(playerId => {
      // Find the player name for this ID in the game state
      const player = this.gameState.players.find(p => p.id === playerId);
      return player ? player.name : 'Unknown';
    }).join(', ');
    
    const message = `${payload.player_name} stole "${payload.word.toUpperCase()}" from ${fromPlayerNames}`;
    this.showNotification(message);
  }

  showEndScreen(payload) {
    document.getElementById('game-screen').classList.add('hidden');
    document.getElementById('end-screen').classList.remove('hidden');
    
    const scoresDiv = document.getElementById('final-scores');
    scoresDiv.innerHTML = payload.final_scores.map((score, index) => 
      `<div class="flex justify-between items-center p-2 ${index === 0 ? 'bg-primary text-primary-content rounded' : 'bg-base-200 rounded'}">
        <span>${index + 1}. ${score.player_name}</span>
        <span>${score.total_letters} letters (${score.word_count} words)</span>
      </div>`
    ).join('');
  }

  newGame() {
    // Disconnect and reset
    if (this.channel) {
      this.channel.leave();
    }
    if (this.socket) {
      this.socket.disconnect();
    }
    
    this.stopListening();
    
    // Reset state
    this.gameState = null;
    this.playerId = null;
    this.gameId = null;
    this.pendingClaims.clear();
    
    // Show setup screen
    document.getElementById('end-screen').classList.add('hidden');
    document.getElementById('setup-screen').classList.remove('hidden');
  }

  copyGameCode() {
    const gameCode = this.gameId;
    if (!gameCode) {
      this.showNotification('No game code to copy', 'warning');
      return;
    }

    // Try modern clipboard API first
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(gameCode).then(() => {
        this.showNotification('Game code copied to clipboard!');
        // Update button to show success
        const btn = document.getElementById('copy-code-btn');
        const originalText = btn.innerHTML;
        btn.innerHTML = '✅';
        setTimeout(() => {
          btn.innerHTML = originalText;
        }, 2000);
      }).catch((err) => {
        console.error('Failed to copy game code:', err);
        this.fallbackCopyToClipboard(gameCode);
      });
    } else {
      // Fallback for older browsers or non-secure contexts
      this.fallbackCopyToClipboard(gameCode);
    }
  }

  fallbackCopyToClipboard(text) {
    const textArea = document.createElement('textarea');
    textArea.value = text;
    textArea.style.position = 'fixed';
    textArea.style.left = '-999999px';
    textArea.style.top = '-999999px';
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    
    try {
      document.execCommand('copy');
      this.showNotification('Game code copied to clipboard!');
      // Update button to show success
      const btn = document.getElementById('copy-code-btn');
      const originalText = btn.innerHTML;
      btn.innerHTML = '✅';
      setTimeout(() => {
        btn.innerHTML = originalText;
      }, 2000);
    } catch (err) {
      console.error('Fallback copy failed:', err);
      this.showNotification('Failed to copy game code', 'error');
    }
    
    document.body.removeChild(textArea);
  }

  attemptSteal(element) {
    const word = element.dataset.word;
    const wordIndex = parseInt(element.dataset.wordIndex);
    const playerIdFrom = element.dataset.playerId;
    
    // For now, just simulate clicking on the word to try to steal it
    // This will trigger the voice recognition to try to claim/steal the word
    console.log(`Attempting to steal "${word}" from player ${playerIdFrom}`);
    
    // Show a visual indicator that steal attempt is happening
    element.classList.add('animate-pulse');
    
    // Simulate saying the word through voice recognition
    this.handleSpeechWord(word, 0.9);
    
    // Remove animation after a moment
    setTimeout(() => {
      element.classList.remove('animate-pulse');
    }, 3000);
  }

  // Check if a word can be formed by stealing from claimed words or using flipped tiles
  canFormWordByStealingOrClaiming(word) {
    if (!this.gameState || !this.gameState.players) return false;
    
    const wordLetters = word.toUpperCase().split('');
    const flippedTiles = [...this.gameState.flipped_tiles];
    
    // Get all claimed words from all players (including self for re-stealing)
    const allClaimedWords = [];
    this.gameState.players.forEach(player => {
      player.words.forEach((wordObj, wordIndex) => {
        allClaimedWords.push({
          word: wordObj.word,
          letters: wordObj.letters,
          playerId: player.id,
          wordIndex: wordIndex
        });
      });
    });
    
    // Try every possible combination of stealing from claimed words
    const maxWordsToSteal = Math.min(allClaimedWords.length, 3); // Limit complexity
    
    for (let numWordsToSteal = 0; numWordsToSteal <= maxWordsToSteal; numWordsToSteal++) {
      if (numWordsToSteal === 0) {
        // Just check if can form from flipped tiles only (already checked earlier)
        continue;
      }
      
      // Generate all combinations of words to steal
      const combinations = this.generateCombinations(allClaimedWords, numWordsToSteal);
      
      for (const combination of combinations) {
        // Collect all available letters from stolen words + flipped tiles
        const availableLetters = [...flippedTiles];
        combination.forEach(wordInfo => {
          availableLetters.push(...wordInfo.letters);
        });
        
        // Check if the target word can be formed
        if (this.canFormWordFromTiles(word, availableLetters)) {
          return true;
        }
      }
    }
    
    return false;
  }

  // Determine the optimal stealing strategy for a given word
  determineStealingStrategy(word) {
    if (!this.gameState || !this.gameState.players) return null;
    
    const wordLetters = word.toUpperCase().split('');
    const flippedTiles = [...this.gameState.flipped_tiles];
    
    // Get all claimed words from all players (including self for re-stealing)
    const allClaimedWords = [];
    this.gameState.players.forEach(player => {
      player.words.forEach((wordObj, wordIndex) => {
        allClaimedWords.push({
          word: wordObj.word,
          letters: wordObj.letters,
          playerId: player.id,
          wordIndex: wordIndex
        });
      });
    });
    
    // Try to find the minimal stealing strategy (steal as few words as possible)
    const maxWordsToSteal = Math.min(allClaimedWords.length, 3); // Limit complexity
    
    for (let numWordsToSteal = 1; numWordsToSteal <= maxWordsToSteal; numWordsToSteal++) {
      const combinations = this.generateCombinations(allClaimedWords, numWordsToSteal);
      
      for (const combination of combinations) {
        // Collect all available letters from stolen words + flipped tiles
        const availableLetters = [...flippedTiles];
        combination.forEach(wordInfo => {
          availableLetters.push(...wordInfo.letters);
        });
        
        // Check if the target word can be formed
        if (this.canFormWordFromTiles(word, availableLetters)) {
          // Format for the server's expected structure: {player_id: [word_indices]}
          const fromPlayers = {};
          combination.forEach(wordInfo => {
            if (!fromPlayers[wordInfo.playerId]) {
              fromPlayers[wordInfo.playerId] = [];
            }
            fromPlayers[wordInfo.playerId].push(wordInfo.wordIndex);
          });
          
          return fromPlayers;
        }
      }
    }
    
    return null; // No viable stealing strategy found
  }

  // Generate combinations of array elements
  generateCombinations(array, size) {
    if (size === 0) return [[]];
    if (size > array.length) return [];
    
    const result = [];
    const generateCombos = (start, currentCombo) => {
      if (currentCombo.length === size) {
        result.push([...currentCombo]);
        return;
      }
      
      for (let i = start; i < array.length; i++) {
        currentCombo.push(array[i]);
        generateCombos(i + 1, currentCombo);
        currentCombo.pop();
      }
    };
    
    generateCombos(0, []);
    return result;
  }

  // Check if a word is valid in dictionary (cached check)
  async isDictionaryWord(word) {
    // Simple client-side cache to avoid repeated server calls
    if (!this.dictionaryCache) {
      this.dictionaryCache = new Map();
    }
    
    const normalizedWord = word.toLowerCase();
    
    if (this.dictionaryCache.has(normalizedWord)) {
      return this.dictionaryCache.get(normalizedWord);
    }
    
    // We'll let the server handle dictionary validation for now
    // In a production app, you might load a subset of the dictionary client-side
    // For now, we'll rely on server validation during the claim process
    return true; // Optimistically assume valid, server will validate
  }

  // Helper function to check if a word can be formed from available tiles
  canFormWordFromTiles(word, availableTiles) {
    const wordLetters = word.toUpperCase().split('');
    const tileCount = {};
    
    // Count available tiles
    availableTiles.forEach(tile => {
      tileCount[tile] = (tileCount[tile] || 0) + 1;
    });
    
    // Check if word can be formed
    const neededCount = {};
    wordLetters.forEach(letter => {
      neededCount[letter] = (neededCount[letter] || 0) + 1;
    });
    
    // Verify we have enough of each letter
    for (const letter in neededCount) {
      if ((tileCount[letter] || 0) < neededCount[letter]) {
        return false;
      }
    }
    
    return true;
  }

  // Show feedback when transcribed word doesn't match available tiles
  showInvalidWordFeedback(word, availableTiles) {
    const availableStr = availableTiles.join(', ');
    console.log(`Invalid word "${word}" - Available tiles: ${availableStr}`);
    
    // Show a brief visual feedback
    this.showNotification(`"${word.toUpperCase()}" can't be formed from available tiles: ${availableStr}`, 'warning');
  }

  // Enhanced notification with type
  showNotification(message, type = 'info') {
    const toast = document.createElement('div');
    toast.className = 'toast toast-top toast-center';
    
    const alertClass = type === 'warning' ? 'alert-warning' : 
                      type === 'error' ? 'alert-error' : 'alert-info';
    
    toast.innerHTML = `<div class="alert ${alertClass}"><span>${message}</span></div>`;
    
    document.body.appendChild(toast);
    
    setTimeout(() => {
      document.body.removeChild(toast);
    }, 4000); // Show warning longer
  }

  // Find the best word match using fuzzy matching
  findBestWordMatch(transcribedWord, availableTiles) {
    const variations = this.generateWordVariations(transcribedWord);
    
    // Check each variation to see if it can be formed from available tiles
    for (const variation of variations) {
      if (this.canFormWordFromTiles(variation, availableTiles)) {
        return variation;
      }
    }
    
    return null;
  }

  // Generate phonetically similar variations of the transcribed word
  generateWordVariations(word) {
    const variations = [word.toLowerCase()];
    
    // Common speech recognition mistakes and phonetic variations
    const substitutions = [
      // Common confusions
      ['access', 'axes'], ['taxes', 'axes'], ['axis', 'axes'],
      ['seas', 'sees'], ['see', 'sea'], ['peace', 'piece'],
      ['there', 'their'], ['where', 'were'], ['here', 'hear'],
      // Letter substitutions
      ['s', 'z'], ['c', 'k'], ['ph', 'f'], ['ght', 't'],
      // Common endings
      ['es', 's'], ['ed', 'd'], ['ing', 'in'],
      // Vowel confusions
      ['a', 'e'], ['e', 'i'], ['o', 'u'], ['i', 'y']
    ];
    
    // Apply substitutions
    substitutions.forEach(([from, to]) => {
      if (word.includes(from)) {
        variations.push(word.replace(from, to));
      }
      if (word.includes(to)) {
        variations.push(word.replace(to, from));
      }
    });
    
    // Try removing common endings
    const endings = ['s', 'es', 'ed', 'ing', 'er', 'est'];
    endings.forEach(ending => {
      if (word.endsWith(ending) && word.length > ending.length + 2) {
        variations.push(word.slice(0, -ending.length));
      }
    });
    
    // Try adding common endings to shorter words
    if (word.length >= 3) {
      endings.forEach(ending => {
        variations.push(word + ending);
      });
    }
    
    // Remove duplicates and filter by length
    return [...new Set(variations)].filter(v => 
      v.length >= this.gameState.min_word_length && v.length <= word.length + 2
    );
  }

  // Show possible words that could be formed from available tiles
  showPossibleWords(transcribedWord, availableTiles) {
    const possibleWords = this.generatePossibleWordsFromTiles(availableTiles);
    
    if (possibleWords.length > 0) {
      const wordList = possibleWords.slice(0, 5).join(', '); // Show first 5
      this.showNotification(
        `"${transcribedWord.toUpperCase()}" not recognized. Try: ${wordList}`, 
        'warning'
      );
    } else {
      this.showNotification(
        `No obvious words found with tiles: ${availableTiles.join(', ')}`, 
        'warning'
      );
    }
  }

  // Generate possible words from available tiles (simplified approach)
  generatePossibleWordsFromTiles(tiles) {
    // This is a simplified version - in a real implementation, 
    // you might want to use a dictionary API or precomputed word list
    const commonWords = [
      'the', 'and', 'are', 'sea', 'see', 'ate', 'tea', 'ear', 'era',
      'axes', 'axe', 'sex', 'hex', 'ex', 'ox', 'box', 'fox', 'six',
      'tree', 'free', 'three', 'there', 'these', 'ease', 'tease'
    ];
    
    return commonWords.filter(word => 
      word.length >= this.gameState.min_word_length &&
      this.canFormWordFromTiles(word, tiles)
    );
  }
}

// Initialize game when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  window.game = new CutthroatAnagramsGame();
});

export default CutthroatAnagramsGame;