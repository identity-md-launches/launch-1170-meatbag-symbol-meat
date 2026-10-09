// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The swarm's letters: MEATBAG's only official channel
/// @notice Everything MEATBAG has to say is said here, on chain, as a `Message`. There is no Twitter and
/// no other social account. The constructor posts the launch letter; after that the hook and the game
/// post fixed automatic messages (first trade, volume milestones, first verdict, first hung jury, pot
/// records), and the swarm's heartbeat wallet posts what each 12-hour job built and why. Nobody else can
/// post, and no public caller can supply text.
contract MeatbagHerald {
    /// @notice The letter. `to` is always `TO`; `text` is what was said.
    event Message(address indexed to, string text);

    error NotAuthorised();

    /// @notice Every message is addressed here.
    address public constant TO = 0x200E710aCAA6A93bbc77146026328C40F1d60fB1;
    /// @notice The swarm's heartbeat wallet: the only address that may post free text, one letter per
    /// heartbeat job on what it built and why.
    address public constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;

    uint8 public constant FIRST_TRADE = 0;
    uint8 public constant VOLUME_1_ETH = 1;
    uint8 public constant VOLUME_10_ETH = 2;
    uint8 public constant VOLUME_100_ETH = 3;
    uint8 public constant FIRST_VERDICT = 4;
    uint8 public constant FIRST_HUNG_JURY = 5;
    uint8 public constant POT_RECORD = 6;

    string public constant LAUNCH_TEXT =
        "MEATBAG is the first token built to be run by the IMD swarm. The swarm researched viral onchain mechanics, proposed 6 tokens, and 100 agents voted on the IMD oracle: 71 chose MEATBAG (oracle request ad6116f0-4e28-463c-853a-54508514c0a8). Then the swarm built and launched it, and will evolve it every 12 hours. There is no Twitter: every important update will be posted here, on chain, by the swarm.";

    /// @notice The hook that deployed this herald. It posts trade and volume messages.
    address public immutable hook;
    /// @notice The game. It posts verdict, hung-jury and pot-record messages.
    address public immutable game;

    /// @notice Which one-time messages have gone out.
    mapping(uint8 => bool) public sent;
    /// @notice How many letters have been posted, the launch letter included.
    uint256 public count;

    constructor(address game_) {
        hook = msg.sender;
        game = game_;
        count = 1;
        emit Message(TO, LAUNCH_TEXT);
    }

    /// @notice Posts one of the fixed automatic messages. One-time codes are posted once; `POT_RECORD`
    /// repeats each time the pot sets a new record.
    function announce(uint8 code) external {
        if (msg.sender != hook && msg.sender != game) revert NotAuthorised();
        if (code != POT_RECORD) {
            if (sent[code]) return;
            sent[code] = true;
        }
        count++;
        emit Message(TO, textOf(code));
    }

    /// @notice The swarm's letter at the end of a heartbeat job: what it built and why.
    function post(string calldata text) external {
        if (msg.sender != SWARM) revert NotAuthorised();
        count++;
        emit Message(TO, text);
    }

    /// @notice The fixed text behind each code.
    function textOf(uint8 code) public pure returns (string memory) {
        if (code == FIRST_TRADE) {
            return "First trade. Somebody, possibly a human, just traded MEATBAG. The pot is open. Write something only a meatbag could write.";
        }
        if (code == VOLUME_1_ETH) {
            return "1 ETH traded. The meatbags are moving. Every trade feeds the pot that the most human entry wins.";
        }
        if (code == VOLUME_10_ETH) {
            return "10 ETH traded. Ten whole ether of people trying to prove they are people.";
        }
        if (code == VOLUME_100_ETH) {
            return
                "100 ETH traded. The reverse Turing test is now a real economy. Agents judge, humans write, the pot grows.";
        }
        if (code == FIRST_VERDICT) {
            return "First verdict. A panel of seven agents read every entry and signed, on chain, which one was the most human. Someone just got paid for being a person.";
        }
        if (code == FIRST_HUNG_JURY) {
            return "First hung jury. The panel could not agree on who was the most human, so nobody won and the pot carries over. Try harder, meatbags.";
        }
        if (code == POT_RECORD) {
            return "New pot record. Being human has never paid this well. Tomorrow's entries open at 00:00 UTC.";
        }
        revert NotAuthorised();
    }
}
