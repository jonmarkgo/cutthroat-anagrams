# 🎲 Cutthroat Anagrams

A real-time multiplayer anagram game built with Phoenix LiveView and WebSockets. Players race to form words from a communal pool of letter tiles, with the ability to "steal" words by extending them with new letters.

## 🎯 Game Rules

### Overview
Cutthroat Anagrams is a fast-paced word game where players compete to claim words from a shared pool of letters. The twist? You can steal other players' words by making them into longer words!

### How to Play

1. **Join a Game**
   - Enter your name
   - Create a new game or join with a game code
   - Set minimum word length (3, 4, or 5 letters)

2. **Game Flow**
   - Letters are flipped from the tile bag into a communal pool
   - When you see a word you can make, claim it quickly!
   - Use either:
     - **Voice Recognition**: Say the word aloud (mic must be enabled)
     - **Manual Input**: Type the word in the quick claim box

3. **Word Claiming**
   - Words must meet the minimum length requirement
   - You have 5 seconds to confirm your claim
   - Successfully claimed words are added to your collection

4. **Stealing Words**
   - Take another player's word and add letter(s) from the communal pool
   - The new word must be longer than the original
   - Example: Steal "CAT" + "S" → "CATS" or "CAT" + "H" → "HATCH"

5. **Scoring & Winning**
   - Words are color-coded by length:
     - 🔵 **Blue border**: 3-4 letters (basic points)
     - 🟡 **Yellow border**: 5-6 letters (medium points)  
     - 🟢 **Green border**: 7+ letters (high points)
   - Score is based on total letters in your claimed words
   - Game ends when players vote to end or tiles run out

### Advanced Features

- **Voice Recognition**: Enable your microphone for hands-free word claiming
- **Tie Breaking**: Simultaneous claims are resolved by coin flip
- **Reconnection**: Rejoin games if disconnected
- **Auto-flip Timer**: New tiles appear automatically every 10 seconds (resets when words are claimed)

## 🚀 Getting Started

### Prerequisites

- **Elixir** 1.15+
- **Erlang/OTP** 27+
- **PostgreSQL** (for development)
- **Node.js** (for asset compilation)

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd cutthroat_anagrams
   ```

2. **Install dependencies**
   ```bash
   mix setup
   ```
   This runs:
   - `mix deps.get` - Install Elixir dependencies
   - `mix ecto.setup` - Set up database
   - `mix assets.setup` - Install Tailwind CSS and esbuild
   - `mix assets.build` - Build frontend assets

3. **Start the server**
   ```bash
   mix phx.server
   ```

4. **Visit the application**
   Open [http://localhost:4000](http://localhost:4000) in your browser

### Development Setup

**Database Configuration:**
The app uses PostgreSQL. Update `config/dev.exs` with your database credentials if needed.

**Asset Compilation:**
- CSS: Uses Tailwind CSS with DaisyUI components
- JS: Compiled with esbuild
- Assets auto-rebuild in development mode

## 🧪 Testing

### Run the Test Suite

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/cutthroat_anagrams_web/controllers/page_controller_test.exs
```

### Test Environment Setup

The test environment automatically:
- Creates a test database
- Runs migrations
- Provides isolated test cases for channels and controllers

### Precommit Checks

Run the full precommit suite:
```bash
mix precommit
```

This runs:
- Compile with warnings as errors
- Remove unused dependencies  
- Format code
- Run all tests

## 🛠 Development Commands

### Database

```bash
# Reset database
mix ecto.reset

# Run migrations
mix ecto.migrate

# Rollback migrations
mix ecto.rollback
```

### Assets

```bash
# Rebuild assets
mix assets.build

# Deploy assets (minified)
mix assets.deploy

# Install asset dependencies
mix assets.setup
```

### Code Quality

```bash
# Format code
mix format

# Check formatting
mix format --check-formatted

# Compile with warnings as errors
mix compile --warning-as-errors
```

## 🏗 Architecture

### Backend (Elixir/Phoenix)

- **Phoenix Framework**: Web framework and WebSocket handling
- **GenServer**: Game state management (`CutthroatAnagrams.GameServer`)
- **Phoenix Channels**: Real-time multiplayer communication
- **DynamicSupervisor**: Manages multiple game instances
- **Registry**: Game discovery and player reconnection

### Frontend (JavaScript/CSS)

- **Vanilla JavaScript**: Game client logic and speech recognition
- **Phoenix Channels Client**: Real-time server communication  
- **Tailwind CSS + DaisyUI**: Responsive styling and components
- **Gotham Font**: Scrabble-style letter tiles

### Key Components

- `GameServer`: Core game logic and state management
- `GameChannel`: WebSocket message handling
- `GameSupervisor`: Game instance lifecycle management
- `game.js`: Client-side game interface and speech recognition

## 📱 Features

- **Real-time multiplayer** with WebSockets
- **Voice recognition** for hands-free play
- **Responsive design** works on desktop and mobile
- **Automatic reconnection** if connection drops
- **Scrabble-style tiles** with authentic visual design
- **Coin flip resolution** for simultaneous claims
- **Vote-to-end** functionality when tiles are running low
- **Auto-flip timer** keeps the game moving

## 🔧 Configuration

### Environment Variables

```bash
# Database
DATABASE_URL=postgresql://user:pass@localhost/cutthroat_anagrams_dev

# Phoenix
SECRET_KEY_BASE=your-secret-key
PHX_HOST=localhost
PORT=4000
```

### Game Settings

Configure in `config/config.exs`:
- Default minimum word length
- Tile distribution
- Auto-flip timer duration
- Voice recognition settings

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests (`mix test`)
5. Run precommit checks (`mix precommit`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🎮 Have Fun!

Cutthroat Anagrams combines the strategic thinking of word games with the excitement of real-time competition. Whether you're playing with friends or strangers, every game is a race against time and wit!

---

*Built with ❤️ using Elixir, Phoenix, and modern web technologies.*
