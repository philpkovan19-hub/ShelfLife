// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ShelfLife
 * @notice Consignment with automatic markdown, on BOT Chain.
 *
 * A shop opens with a commission rate. A consignor puts an item on the shelf
 * with a start price, a floor, a markdown step and a term. From then on the
 * price steps down **on its own**: nobody has to re-list, re-price or be
 * online. `priceOf` is a pure function of the clock, so what a buyer pays is
 * what anyone could have computed in advance.
 *
 * Three things follow from that:
 *  - The shop cannot raise a price or pause the markdown. The schedule is
 *    fixed at consignment.
 *  - The price never falls through the floor the consignor set.
 *  - Past the term the shelf is closed. The item is returned to the consignor,
 *    not quietly marked down to nothing.
 *
 * Money is split at the moment of sale and held per party until pulled, so a
 * shop that goes quiet cannot strand a consignor's proceeds.
 */
contract ShelfLife is Ownable, Pausable, ReentrancyGuard {
    enum Status {
        OnShelf,
        Sold,
        Returned
    }

    struct Shop {
        address keeper;
        string name;
        uint16 commissionBps;
        bool accepting;
        uint32 itemsTaken;
        uint32 itemsSold;
    }

    struct Item {
        uint64 shopId;
        address consignor;
        uint256 startPrice;
        uint256 floorPrice;
        uint16 stepBps;
        uint64 stepSecs;
        uint64 listedAt;
        uint64 term;
        uint256 soldFor;
        address buyer;
        Status status;
        string title;
    }

    uint16 public constant MAX_COMMISSION_BPS = 4000;
    uint16 public constant MAX_STEP_BPS = 2000;
    uint64 public constant MIN_STEP_SECS = 1 hours;
    uint64 public constant MAX_STEP_SECS = 30 days;
    uint64 public constant MIN_TERM = 1 days;
    uint64 public constant MAX_TERM = 365 days;
    uint256 public constant MIN_PRICE = 0.001 ether;
    uint256 public constant MAX_TEXT = 64;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Protocol fee, taken from the sale price alongside the shop's commission.
    uint16 public feeBps = 150;

    uint256 public accumulatedFees;
    /// @notice Proceeds credited to consignors and shops but not yet pulled.
    uint256 public lockedTotal;

    Shop[] private _shops;
    Item[] private _items;
    mapping(uint256 => uint256[]) private _shopItems;
    mapping(address => uint256[]) private _byConsignor;
    mapping(address => uint256) public proceeds;

    event ShopOpened(uint256 indexed shopId, address indexed keeper, string name, uint16 commissionBps);
    event ShopAccepting(uint256 indexed shopId, bool accepting);
    event Consigned(uint256 indexed itemId, uint256 indexed shopId, address indexed consignor, string title, uint256 startPrice, uint256 floorPrice, uint16 stepBps, uint64 stepSecs, uint64 term);
    event Sold(uint256 indexed itemId, address indexed buyer, uint256 price, uint256 toConsignor, uint256 toShop, uint256 fee);
    event ItemReturned(uint256 indexed itemId, address indexed consignor, bool pulledEarly);
    event ProceedsWithdrawn(address indexed who, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // --------------------------------------------------------------- shops

    function openShop(string calldata name, uint16 commissionBps)
        external
        whenNotPaused
        returns (uint256 shopId)
    {
        require(bytes(name).length > 0 && bytes(name).length <= MAX_TEXT, "bad name");
        require(commissionBps <= MAX_COMMISSION_BPS, "commission too high");
        shopId = _shops.length;
        _shops.push(
            Shop({
                keeper: msg.sender,
                name: name,
                commissionBps: commissionBps,
                accepting: true,
                itemsTaken: 0,
                itemsSold: 0
            })
        );
        emit ShopOpened(shopId, msg.sender, name, commissionBps);
    }

    /// @dev Stops new consignments. Items already on the shelf keep selling.
    function setAccepting(uint256 shopId, bool accepting) external {
        Shop storage s = _shop(shopId);
        require(s.keeper == msg.sender, "not keeper");
        s.accepting = accepting;
        emit ShopAccepting(shopId, accepting);
    }

    // --------------------------------------------------------------- items

    /**
     * @notice Put an item on the shelf. The markdown schedule is fixed here
     *         and cannot be changed afterwards by anyone.
     */
    function consign(
        uint256 shopId,
        string calldata title,
        uint256 startPrice,
        uint256 floorPrice,
        uint16 stepBps,
        uint64 stepSecs,
        uint64 term
    ) external whenNotPaused returns (uint256 itemId) {
        Shop storage s = _shop(shopId);
        require(s.accepting, "not accepting");
        require(s.keeper != msg.sender, "keeper cannot consign to own shop");
        require(bytes(title).length > 0 && bytes(title).length <= MAX_TEXT, "bad title");
        require(startPrice >= MIN_PRICE, "start below minimum");
        require(floorPrice >= MIN_PRICE && floorPrice <= startPrice, "bad floor");
        require(stepBps > 0 && stepBps <= MAX_STEP_BPS, "bad step");
        require(stepSecs >= MIN_STEP_SECS && stepSecs <= MAX_STEP_SECS, "bad step interval");
        require(term >= MIN_TERM && term <= MAX_TERM, "bad term");

        itemId = _items.length;
        _items.push(
            Item({
                shopId: uint64(shopId),
                consignor: msg.sender,
                startPrice: startPrice,
                floorPrice: floorPrice,
                stepBps: stepBps,
                stepSecs: stepSecs,
                listedAt: uint64(block.timestamp),
                term: term,
                soldFor: 0,
                buyer: address(0),
                status: Status.OnShelf,
                title: title
            })
        );
        _shopItems[shopId].push(itemId);
        _byConsignor[msg.sender].push(itemId);
        unchecked {
            s.itemsTaken += 1;
        }
        emit Consigned(itemId, shopId, msg.sender, title, startPrice, floorPrice, stepBps, stepSecs, term);
    }

    /**
     * @notice Buy at today's marked-down price. Overpayment is returned, so a
     *         buyer racing a markdown step never loses the difference.
     */
    function buy(uint256 itemId) external payable nonReentrant whenNotPaused {
        Item storage it = _item(itemId);
        require(it.status == Status.OnShelf, "not on the shelf");
        require(block.timestamp < uint256(it.listedAt) + it.term, "term expired");
        require(msg.sender != it.consignor, "consignor cannot buy");

        uint256 price = _priceOf(it);
        require(msg.value >= price, "under the shelf price");

        Shop storage s = _shops[it.shopId];
        it.status = Status.Sold;
        it.soldFor = price;
        it.buyer = msg.sender;
        unchecked {
            s.itemsSold += 1;
        }

        uint256 fee = (price * feeBps) / 10_000;
        uint256 commission = (price * s.commissionBps) / 10_000;
        uint256 toConsignor = price - fee - commission;

        accumulatedFees += fee;
        proceeds[it.consignor] += toConsignor;
        proceeds[s.keeper] += commission;
        lockedTotal += toConsignor + commission;

        emit Sold(itemId, msg.sender, price, toConsignor, commission, fee);

        uint256 change = msg.value - price;
        if (change > 0) {
            (bool ok, ) = payable(msg.sender).call{value: change}("");
            require(ok, "change failed");
        }
    }

    /**
     * @notice Take the item off the shelf. The consignor may do this at any
     *         time — the goods are theirs. The keeper may only do it once the
     *         term has run out.
     */
    function returnItem(uint256 itemId) external {
        Item storage it = _item(itemId);
        require(it.status == Status.OnShelf, "not on the shelf");

        bool expired = block.timestamp >= uint256(it.listedAt) + it.term;
        if (msg.sender == it.consignor) {
            // Always allowed.
        } else if (msg.sender == _shops[it.shopId].keeper) {
            require(expired, "term still running");
        } else {
            revert("not a party");
        }

        it.status = Status.Returned;
        emit ItemReturned(itemId, it.consignor, !expired);
    }

    /// @dev Pull payment. Works while paused; credited proceeds are owed.
    function withdrawProceeds() external nonReentrant {
        uint256 amount = proceeds[msg.sender];
        require(amount > 0, "nothing to withdraw");
        proceeds[msg.sender] = 0;
        lockedTotal -= amount;
        emit ProceedsWithdrawn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // --------------------------------------------------------------- views

    /**
     * @notice Today's price. Steps down by `stepBps` of the start price every
     *         `stepSecs`, never below the floor.
     */
    function priceOf(uint256 itemId) external view returns (uint256) {
        return _priceOf(_item(itemId));
    }

    /// @notice How many markdown steps have been applied so far.
    function stepsTaken(uint256 itemId) external view returns (uint256) {
        Item storage it = _item(itemId);
        return (block.timestamp - it.listedAt) / it.stepSecs;
    }

    /// @notice Seconds until the next markdown. Zero once the price sits on the floor.
    function nextStepIn(uint256 itemId) external view returns (uint256) {
        Item storage it = _item(itemId);
        if (_priceOf(it) == it.floorPrice) return 0;
        uint256 elapsed = block.timestamp - it.listedAt;
        return it.stepSecs - (elapsed % it.stepSecs);
    }

    /// @notice When the shelf closes and the item goes back to its consignor.
    function expiresAt(uint256 itemId) external view returns (uint256) {
        Item storage it = _item(itemId);
        return uint256(it.listedAt) + it.term;
    }

    function isOnShelf(uint256 itemId) external view returns (bool) {
        Item storage it = _item(itemId);
        return it.status == Status.OnShelf && block.timestamp < uint256(it.listedAt) + it.term;
    }

    function shopCount() external view returns (uint256) {
        return _shops.length;
    }

    function itemCount() external view returns (uint256) {
        return _items.length;
    }

    function getShop(uint256 shopId) external view returns (Shop memory) {
        return _shop(shopId);
    }

    function getItem(uint256 itemId) external view returns (Item memory) {
        return _item(itemId);
    }

    function getShopItems(uint256 shopId) external view returns (uint256[] memory) {
        return _shopItems[shopId];
    }

    function itemsByConsignor(address who) external view returns (uint256[] memory) {
        return _byConsignor[who];
    }

    function getRecentShops(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _shops.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    function getRecentItems(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _items.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`; credited proceeds are unreachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _priceOf(Item storage it) private view returns (uint256) {
        uint256 steps = (block.timestamp - it.listedAt) / it.stepSecs;
        uint256 cut = (it.startPrice * it.stepBps * steps) / 10_000;
        if (cut >= it.startPrice) return it.floorPrice;
        uint256 p = it.startPrice - cut;
        return p < it.floorPrice ? it.floorPrice : p;
    }

    function _shop(uint256 id) private view returns (Shop storage) {
        require(id < _shops.length, "no such shop");
        return _shops[id];
    }

    function _item(uint256 id) private view returns (Item storage) {
        require(id < _items.length, "no such item");
        return _items[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
