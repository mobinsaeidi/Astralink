// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract AstralinkDomainMarket is ERC721URIStorage, Ownable {
    IERC20 public paymentToken;
    uint256 private _tokenIdCounter; // جایگزین Counters

    // === ساختارهای اصلی ===
    struct Listing {
        address seller;
        uint256 price;
        uint256 expiresAt;
    }

    struct Offer {
        address buyer;
        uint256 price;
        uint256 expiresAt;
        bool active;
    }

    struct Fraction {
        address owner;
        uint256 shares;
        uint256 totalShares;
    }

    struct CommunityOffer {
        address initiator;
        uint256 totalPrice;
        uint256 minParticipants;
        uint256 currentParticipants;
        uint256 expiresAt;
        address[] participants;
        mapping(address => uint256) contributions;
        bool fulfilled;
    }

    struct Message {
        address sender;
        string content;
        uint256 timestamp;
        string xmtpMessageId;
    }

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Offer[]) public offers;
    mapping(uint256 => Fraction[]) public fractions;
    mapping(uint256 => Message[]) private domainMessages;
    mapping(uint256 => mapping(string => bool)) public xmtpMessageIds;
    mapping(uint256 => CommunityOffer) public communityOffers;
    mapping(uint256 => uint256) public domainStats;

    // === ایونت‌ها ===
    event DomainMinted(uint256 tokenId, address owner, string uri);
    event DomainListed(uint256 tokenId, address seller, uint256 price, uint256 expiresAt);
    event DomainSold(uint256 tokenId, address buyer, uint256 price);
    event ListingCanceled(uint256 tokenId, address seller);
    event OfferMade(uint256 tokenId, address buyer, uint256 price, uint256 expiresAt);
    event OfferAccepted(uint256 tokenId, address buyer, uint256 price);
    event OfferCanceled(uint256 tokenId, address buyer);
    event DomainMessageSent(uint256 tokenId, address sender, string content, uint256 timestamp, string xmtpMessageId);
    event DomainFractionalized(uint256 tokenId, uint256 totalShares);
    event FractionSold(uint256 tokenId, address buyer, uint256 shares, uint256 price);
    event CommunityOfferCreated(uint256 tokenId, address initiator, uint256 totalPrice, uint256 minParticipants);
    event CommunityOfferJoined(uint256 tokenId, address participant, uint256 contribution);
    event CommunityOfferFulfilled(uint256 tokenId, uint256 totalRaised);
    event SEODataUpdated(uint256 tokenId, string seoKeywords, string metadata);

    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        address _paymentToken
    ) ERC721(name, symbol) Ownable(initialOwner) {
        paymentToken = IERC20(_paymentToken);
        _tokenIdCounter = 0; // شروع از صفر
    }

    // === Mint Domain ===
    function mintDomain(string memory domainURI) external onlyOwner {
        uint256 newTokenId = _tokenIdCounter;
        _tokenIdCounter++; // افزایش شمارنده
        _mint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, domainURI);
        emit DomainMinted(newTokenId, msg.sender, domainURI);
    }

    // === Listings ===
    function listDomain(uint256 tokenId, uint256 price, uint256 duration) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(price > 0, "Price must be > 0");
        listings[tokenId] = Listing(msg.sender, price, block.timestamp + duration);
        emit DomainListed(tokenId, msg.sender, price, block.timestamp + duration);
    }

    function cancelListing(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(listings[tokenId].price > 0, "Not listed");
        delete listings[tokenId];
        emit ListingCanceled(tokenId, msg.sender);
    }

    function buyDomain(uint256 tokenId) external {
        Listing memory listing = listings[tokenId];
        require(listing.price > 0, "Not listed");
        require(listing.expiresAt > block.timestamp, "Listing expired");

        require(paymentToken.transferFrom(msg.sender, listing.seller, listing.price), "Payment failed");
        _transfer(listing.seller, msg.sender, tokenId);
        domainStats[tokenId] += 1;
        emit DomainSold(tokenId, msg.sender, listing.price);
        delete listings[tokenId];
    }

    // === Offers ===
    function makeOffer(uint256 tokenId, uint256 price, uint256 duration) external {
        require(_exists(tokenId), "Domain does not exist");
        require(price > 0 && duration > 0, "Invalid offer");
        offers[tokenId].push(Offer(msg.sender, price, block.timestamp + duration, true));
        emit OfferMade(tokenId, msg.sender, price, block.timestamp + duration);
    }

    function acceptOffer(uint256 tokenId, uint256 offerIndex) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        Offer storage offer = offers[tokenId][offerIndex];
        require(offer.active && offer.expiresAt > block.timestamp, "Offer invalid");

        require(paymentToken.transferFrom(offer.buyer, msg.sender, offer.price), "Payment failed");
        _transfer(msg.sender, offer.buyer, tokenId);
        domainStats[tokenId] += 1;
        emit OfferAccepted(tokenId, offer.buyer, offer.price);
        offer.active = false;
    }

    function cancelOffer(uint256 tokenId, uint256 offerIndex) external {
        Offer storage offer = offers[tokenId][offerIndex];
        require(offer.buyer == msg.sender && offer.active, "Not authorized");
        offer.active = false;
        emit OfferCanceled(tokenId, msg.sender);
    }

    // === Fractionalization ===
    function fractionalizeDomain(uint256 tokenId, uint256 totalShares) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(totalShares > 0, "Shares must be > 0");
        _transfer(msg.sender, address(this), tokenId);
        fractions[tokenId].push(Fraction(msg.sender, totalShares, totalShares));
        emit DomainFractionalized(tokenId, totalShares);
    }

    function buyFraction(uint256 tokenId, uint256 shares) external {
        require(fractions[tokenId].length > 0 && shares > 0, "Invalid");
        Fraction storage fraction = fractions[tokenId][0];
        uint256 price = (listings[tokenId].price * shares) / fraction.totalShares;
        require(paymentToken.transferFrom(msg.sender, fraction.owner, price), "Payment failed");
        fractions[tokenId].push(Fraction(msg.sender, shares, fraction.totalShares));
        emit FractionSold(tokenId, msg.sender, shares, price);
    }

    // === Community Offers ===
    function createCommunityOffer(uint256 tokenId, uint256 totalPrice, uint256 minParticipants, uint256 duration) external {
        require(_exists(tokenId) && totalPrice > 0 && minParticipants > 1, "Invalid");
        CommunityOffer storage co = communityOffers[tokenId];
        co.initiator = msg.sender;
        co.totalPrice = totalPrice;
        co.minParticipants = minParticipants;
        co.expiresAt = block.timestamp + duration;
        co.fulfilled = false;
        emit CommunityOfferCreated(tokenId, msg.sender, totalPrice, minParticipants);
    }

    function joinCommunityOffer(uint256 tokenId, uint256 contribution) external {
        CommunityOffer storage co = communityOffers[tokenId];
        require(!co.fulfilled && co.expiresAt > block.timestamp && contribution > 0, "Invalid");
        co.participants.push(msg.sender);
        co.contributions[msg.sender] = contribution;
        co.currentParticipants++;
        require(paymentToken.transferFrom(msg.sender, address(this), contribution), "Payment failed");
        emit CommunityOfferJoined(tokenId, msg.sender, contribution);
        if (co.currentParticipants >= co.minParticipants) _fulfillCommunityOffer(tokenId);
    }

    function _fulfillCommunityOffer(uint256 tokenId) internal {
        CommunityOffer storage co = communityOffers[tokenId];
        require(ownerOf(tokenId) == co.initiator, "Initiator no longer owner");
        uint256 totalRaised;
        for (uint256 i; i < co.participants.length; i++) totalRaised += co.contributions[co.participants[i]];
        require(paymentToken.transfer(co.initiator, totalRaised), "Transfer failed");
        _transfer(co.initiator, address(this), tokenId);
        co.fulfilled = true;
        emit CommunityOfferFulfilled(tokenId, totalRaised);
    }

    // === Messaging (XMTP) ===
    function sendMessageWithXMTP(uint256 tokenId, string memory content, string memory xmtpMessageId) external {
        require(_exists(tokenId) && !xmtpMessageIds[tokenId][xmtpMessageId], "Invalid");
        domainMessages[tokenId].push(Message(msg.sender, content, block.timestamp, xmtpMessageId));
        xmtpMessageIds[tokenId][xmtpMessageId] = true;
        emit DomainMessageSent(tokenId, msg.sender, content, block.timestamp, xmtpMessageId);
    }

    // === SEO & Analytics ===
    function updateSEOMetadata(uint256 tokenId, string memory seoKeywords, string memory metadata) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        emit SEODataUpdated(tokenId, seoKeywords, metadata);
    }

    function getDomainStats(uint256 tokenId) external view returns (uint256) {
        return domainStats[tokenId];
    }

    // === Helpers ===
    function getAllListings() external view returns (uint256[] memory, Listing[] memory) {
        uint256 activeCount;
        for (uint256 i; i < _tokenIdCounter; i++) {
            if (listings[i].price > 0 && listings[i].expiresAt > block.timestamp) activeCount++;
        }
        uint256[] memory tokenIds = new uint256[](activeCount);
        Listing[] memory activeListings = new Listing[](activeCount);
        uint256 idx;
        for (uint256 i; i < _tokenIdCounter; i++) {
            if (listings[i].price > 0 && listings[i].expiresAt > block.timestamp) {
                tokenIds[idx] = i;
                activeListings[idx] = listings[i];
                idx++;
            }
        }
        return (tokenIds, activeListings);
    }

    function getMessages(uint256 tokenId) external view returns (Message[] memory) {
        require(_exists(tokenId), "Domain does not exist");
        return domainMessages[tokenId];
    }

    function getActiveCommunityOffers() external view returns (uint256[] memory) {
        uint256 activeCount;
        for (uint256 i; i < _tokenIdCounter; i++) {
            if (communityOffers[i].expiresAt > block.timestamp && !communityOffers[i].fulfilled) activeCount++;
        }
        uint256[] memory activeOffers = new uint256[](activeCount);
        uint256 idx;
        for (uint256 i; i < _tokenIdCounter; i++) {
            if (communityOffers[i].expiresAt > block.timestamp && !communityOffers[i].fulfilled) {
                activeOffers[idx] = i;
                idx++;
            }
        }
        return activeOffers;
    }
}
