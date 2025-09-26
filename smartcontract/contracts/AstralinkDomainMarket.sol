// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AstralinkDomainMarket is ERC721URIStorage, Ownable {
    IERC20 public paymentToken;
    uint256 private _tokenIdCounter;

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

    struct CommunityOfferData {
        address initiator;
        uint256 totalPrice;
        uint256 minParticipants;
        uint256 currentParticipants;
        uint256 expiresAt;
        bool fulfilled;
    }

    struct Message {
        address sender;
        string content;
        uint256 timestamp;
        string xmtpMessageId;
    }

    // === مپینگ‌ها ===
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Offer[]) public offers;
    mapping(uint256 => Fraction[]) public fractions;
    mapping(uint256 => Message[]) private domainMessages;
    mapping(uint256 => mapping(string => bool)) public xmtpMessageIds;
    mapping(uint256 => CommunityOfferData) public communityOffers;
    mapping(uint256 => address[]) public communityParticipants;
    mapping(uint256 => mapping(address => uint256)) public communityContributions;
    mapping(uint256 => uint256) public domainStats;
    mapping(uint256 => bool) private _existsToken;

    // === ایونت‌های جدید ===
    event OfferExpired(uint256 tokenId, address buyer, uint256 price);
    event FractionalTrade(uint256 tokenId, address from, address to, uint256 shares);
    event DomainViewed(uint256 tokenId, address viewer, uint256 timestamp);
    event PriceUpdated(uint256 tokenId, uint256 oldPrice, uint256 newPrice);
    event BulkListed(address seller, uint256[] tokenIds, uint256 totalPrice);

    // === ایونت‌های اصلی ===
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
        _tokenIdCounter = 1; // شروع از 1
    }

    // === بهبود یافته: Mint Domain با قابلیت‌های جدید ===
    function mintDomain(string memory domainURI) external onlyOwner returns (uint256) {
        uint256 newTokenId = _tokenIdCounter;
        _tokenIdCounter++;
        _mint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, domainURI);
        _existsToken[newTokenId] = true;
        
        emit DomainMinted(newTokenId, msg.sender, domainURI);
        return newTokenId;
    }

    // === بهبود یافته: List Domain با اعتبارسنجی بهتر ===
    function listDomain(uint256 tokenId, uint256 price, uint256 duration) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(price > 0, "Price must be > 0");
        require(duration > 0, "Duration must be > 0");
        
        uint256 oldPrice = listings[tokenId].price;
        listings[tokenId] = Listing({
            seller: msg.sender,
            price: price,
            expiresAt: block.timestamp + duration
        });
        
        emit DomainListed(tokenId, msg.sender, price, block.timestamp + duration);
        if (oldPrice != price && oldPrice > 0) {
            emit PriceUpdated(tokenId, oldPrice, price);
        }
    }

    // === جدید: لیست گروهی دامنه‌ها ===
    function bulkListDomains(uint256[] calldata tokenIds, uint256 price, uint256 duration) external {
        require(tokenIds.length > 0, "No tokens provided");
        require(price > 0, "Price must be > 0");
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(ownerOf(tokenIds[i]) == msg.sender, "Not owner of all tokens");
            listings[tokenIds[i]] = Listing({
                seller: msg.sender,
                price: price,
                expiresAt: block.timestamp + duration
            });
        }
        
        emit BulkListed(msg.sender, tokenIds, price * tokenIds.length);
    }

    function cancelListing(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(listings[tokenId].price > 0, "Not listed");
        
        delete listings[tokenId];
        emit ListingCanceled(tokenId, msg.sender);
    }

    // === بهبود یافته: Buy Domain با آمار پیشرفته ===
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

    // === بهبود یافته: سیستم پیشنهادات با مدیریت انقضا ===
    function makeOffer(uint256 tokenId, uint256 price, uint256 duration) external {
        require(_exists(tokenId), "Domain does not exist");
        require(price > 0, "Price must be > 0");
        require(duration > 0, "Duration must be > 0");
        
        // حذف پیشنهادات منقضی شده
        _cleanExpiredOffers(tokenId);
        
        offers[tokenId].push(Offer({
            buyer: msg.sender,
            price: price,
            expiresAt: block.timestamp + duration,
            active: true
        }));
        
        emit OfferMade(tokenId, msg.sender, price, block.timestamp + duration);
    }

    function  acceptOffer(uint256 tokenId, uint256 offerIndex) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(offerIndex < offers[tokenId].length, "Invalid offer");
        
        Offer storage offer = offers[tokenId][offerIndex];
        require(offer.active, "Offer not active");
        require(offer.expiresAt > block.timestamp, "Offer expired");

        require(paymentToken.transferFrom(offer.buyer, msg.sender, offer.price), "Payment failed");
        _transfer(msg.sender, offer.buyer, tokenId);
        
        domainStats[tokenId] += 1;
        emit OfferAccepted(tokenId, offer.buyer, offer.price);
        offer.active = false;
    }

    function cancelOffer(uint256 tokenId, uint256 offerIndex) external {
        require(offerIndex < offers[tokenId].length, "Invalid offer");
        Offer storage offer = offers[tokenId][offerIndex];
        require(offer.buyer == msg.sender, "Not offer maker");
        require(offer.active, "Offer not active");

        offer.active = false;
        emit OfferCanceled(tokenId, msg.sender);
    }

    // === جدید: مشاهده دامنه (برای آنالیتیکس) ===
    function viewDomain(uint256 tokenId) external {
        require(_exists(tokenId), "Domain does not exist");
        emit DomainViewed(tokenId, msg.sender, block.timestamp);
    }

    // === بهبود یافته: سیستم فروش بخشی ===
    function fractionalizeDomain(uint256 tokenId, uint256 totalShares) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(totalShares > 0, "Shares must be > 0");
        require(fractions[tokenId].length == 0, "Already fractionalized");

        _transfer(msg.sender, address(this), tokenId);
        fractions[tokenId].push(Fraction({
            owner: msg.sender,
            shares: totalShares,
            totalShares: totalShares
        }));
        
        emit DomainFractionalized(tokenId, totalShares);
    }

    function buyFraction(uint256 tokenId, uint256 shares) external {
        require(fractions[tokenId].length > 0, "Not fractionalized");
        require(shares > 0, "Shares must be > 0");

        Fraction storage mainFraction = fractions[tokenId][0];
        require(mainFraction.shares >= shares, "Not enough shares available");

        uint256 pricePerShare = listings[tokenId].price / mainFraction.totalShares;
        uint256 totalPrice = pricePerShare * shares;

        require(paymentToken.transferFrom(msg.sender, mainFraction.owner, totalPrice), "Payment failed");
        
        // کاهش سهام مالک اصلی
        mainFraction.shares -= shares;
        
        // اضافه کردن سهام خریدار
        fractions[tokenId].push(Fraction({
            owner: msg.sender,
            shares: shares,
            totalShares: mainFraction.totalShares
        }));
        
        emit FractionSold(tokenId, msg.sender, shares, totalPrice);
        emit FractionalTrade(tokenId, mainFraction.owner, msg.sender, shares);
    }

    // === بهبود یافته: Community Offers با مدیریت بهتر ===
    function createCommunityOffer(
        uint256 tokenId, 
        uint256 totalPrice, 
        uint256 minParticipants, 
        uint256 duration
    ) external {
        require(_exists(tokenId), "Domain does not exist");
        require(totalPrice > 0, "Price must be > 0");
        require(minParticipants > 1, "Min participants must be > 1");

        communityOffers[tokenId] = CommunityOfferData({
            initiator: msg.sender,
            totalPrice: totalPrice,
            minParticipants: minParticipants,
            currentParticipants: 0,
            expiresAt: block.timestamp + duration,
            fulfilled: false
        });

        emit CommunityOfferCreated(tokenId, msg.sender, totalPrice, minParticipants);
    }

    function joinCommunityOffer(uint256 tokenId, uint256 contribution) external {
        CommunityOfferData storage co = communityOffers[tokenId];
        require(!co.fulfilled, "Offer fulfilled");
        require(co.expiresAt > block.timestamp, "Offer expired");
        require(contribution > 0, "Contribution must be > 0");

        // جلوگیری از مشارکت مجدد
        require(communityContributions[tokenId][msg.sender] == 0, "Already participated");

        communityParticipants[tokenId].push(msg.sender);
        communityContributions[tokenId][msg.sender] = contribution;
        co.currentParticipants++;

        require(paymentToken.transferFrom(msg.sender, address(this), contribution), "Payment failed");
        emit CommunityOfferJoined(tokenId, msg.sender, contribution);

        if (co.currentParticipants >= co.minParticipants) {
            _fulfillCommunityOffer(tokenId);
        }
    }

    function _fulfillCommunityOffer(uint256 tokenId) internal {
        CommunityOfferData storage co = communityOffers[tokenId];
        require(ownerOf(tokenId) == co.initiator, "Initiator no longer owner");

        uint256 totalRaised = 0;
        for (uint256 i = 0; i < communityParticipants[tokenId].length; i++) {
            totalRaised += communityContributions[tokenId][communityParticipants[tokenId][i]];
        }

        require(totalRaised >= co.totalPrice, "Not enough funds raised");
        require(paymentToken.transfer(co.initiator, totalRaised), "Transfer failed");

        // انتقال مالکیت به قرارداد برای مدیریت جامعه
        _transfer(co.initiator, address(this), tokenId);
        co.fulfilled = true;
        
        emit CommunityOfferFulfilled(tokenId, totalRaised);
    }

    // === بهبود یافته: پیام‌رسانی با validation بهتر ===
    function sendMessageWithXMTP(
        uint256 tokenId, 
        string calldata content, 
        string calldata xmtpMessageId
    ) external {
        require(_exists(tokenId), "Domain does not exist");
        require(bytes(content).length > 0, "Content cannot be empty");
        require(!xmtpMessageIds[tokenId][xmtpMessageId], "Message ID already used");

        domainMessages[tokenId].push(Message({
            sender: msg.sender,
            content: content,
            timestamp: block.timestamp,
            xmtpMessageId: xmtpMessageId
        }));

        xmtpMessageIds[tokenId][xmtpMessageId] = true;
        emit DomainMessageSent(tokenId, msg.sender, content, block.timestamp, xmtpMessageId);
    }

    // === جدید: به‌روزرسانی سئو و متادیتا ===
    function updateSEOMetadata(
        uint256 tokenId, 
        string calldata seoKeywords, 
        string calldata metadata
    ) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        emit SEODataUpdated(tokenId, seoKeywords, metadata);
    }

    // === توابع کمکی جدید ===
    function _cleanExpiredOffers(uint256 tokenId) internal {
        for (uint256 i = 0; i < offers[tokenId].length; i++) {
            if (offers[tokenId][i].expiresAt <= block.timestamp && offers[tokenId][i].active) {
                offers[tokenId][i].active = false;
                emit OfferExpired(tokenId, offers[tokenId][i].buyer, offers[tokenId][i].price);
            }
        }
    }

    function getDomainStats(uint256 tokenId) external view returns (uint256) {
        return domainStats[tokenId];
    }

    // === توابع view بهبود یافته ===
    function getAllListings() external view returns (uint256[] memory, Listing[] memory) {
        uint256 activeCount = 0;
        
        // شمارش آیتم‌های فعال
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_existsToken[i] && listings[i].price > 0 && listings[i].expiresAt > block.timestamp) {
                activeCount++;
            }
        }

        uint256[] memory tokenIds = new uint256[](activeCount);
        Listing[] memory activeListings = new Listing[](activeCount);
        uint256 idx = 0;

        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_existsToken[i] && listings[i].price > 0 && listings[i].expiresAt > block.timestamp) {
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
        uint256 activeCount = 0;

        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_existsToken[i] && 
                communityOffers[i].expiresAt > block.timestamp && 
                !communityOffers[i].fulfilled) {
                activeCount++;
            }
        }

        uint256[] memory activeOffers = new uint256[](activeCount);
        uint256 idx = 0;

        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_existsToken[i] && 
                communityOffers[i].expiresAt > block.timestamp && 
                !communityOffers[i].fulfilled) {
                activeOffers[idx] = i;
                idx++;
            }
        }

        return activeOffers;
    }

    function getCommunityOfferDetails(uint256 tokenId) external view returns (
        address initiator,
        uint256 totalPrice,
        uint256 minParticipants,
        uint256 currentParticipants,
        uint256 expiresAt,
        bool fulfilled,
        address[] memory participants
    ) {
        CommunityOfferData memory co = communityOffers[tokenId];
        return (
            co.initiator,
            co.totalPrice,
            co.minParticipants,
            co.currentParticipants,
            co.expiresAt,
            co.fulfilled,
            communityParticipants[tokenId]
        );
    }

    function getFractionHolders(uint256 tokenId) external view returns (address[] memory, uint256[] memory) {
        require(fractions[tokenId].length > 0, "Not fractionalized");
        
        address[] memory holders = new address[](fractions[tokenId].length);
        uint256[] memory shares = new uint256[](fractions[tokenId].length);
        
        for (uint256 i = 0; i < fractions[tokenId].length; i++) {
            holders[i] = fractions[tokenId][i].owner;
            shares[i] = fractions[tokenId][i].shares;
        }
        
        return (holders, shares);
    }

    // === override تابع _exists برای مدیریت بهتر ===
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _existsToken[tokenId];
    }
}