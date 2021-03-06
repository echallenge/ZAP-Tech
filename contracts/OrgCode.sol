pragma solidity 0.4.25;

import "./bases/MultiSig.sol";
import "./open-zeppelin/SafeMath.sol";

import "./interfaces/ICustodian.sol";
import "./interfaces/IGovernance.sol";
import "./interfaces/IIDVerifier.sol";
import "./interfaces/IModules.sol";
import "./interfaces/IOrgShare.sol";

/**
    @title Issuing Entity
    @notice Licensed under GNU GPLv3 - https://github.com/zerolawtech/ZAP-Tech/LICENSE
 */
contract OrgCode is MultiSig {

    using SafeMath32 for uint32;
    using SafeMath for uint256;

    uint256 constant SENDER = 0;
    uint256 constant RECEIVER = 1;

    /*
        Each country can have specific limits for each member class.
        minRating corresponds to the minimum member level for this country.
        counts[0] and levels[0] == the sum total of counts[1:] and limits[1:]
    */
    struct Country {
        uint32[8] counts;
        uint32[8] limits;
        bool permitted;
        uint8 minRating;
    }

    struct Account {
        uint32 count;
        uint8 rating;
        uint8 regKey;
        bool set;
        bool restricted;
        address custodian;
    }

    struct Share {
        bool set;
        bool restricted;
    }

    struct VerifierContract {
        IIDVerifier addr;
        bool restricted;
    }

    IGovernance public governance;
    bool locked;
    VerifierContract[] verifiers;
    uint32[8] counts;
    uint32[8] limits;
    mapping (uint16 => Country) countries;
    mapping (bytes32 => Account) accounts;
    mapping (address => Share) shares;
    mapping (string => bytes32) documentHashes;

    event CountryModified(
        uint16 indexed country,
        bool permitted,
        uint8 minrating,
        uint32[8] limits
    );
    event MemberLimitsSet(uint32[8] limits);
    event NewDocumentHash(string indexed document, bytes32 documentHash);
    event GovernanceSet(address indexed governance);
    event VerifierSet(address indexed verifier, bool restricted);
    event CustodianAdded(address indexed custodian);
    event ShareAdded(address indexed share);
    event EntityRestriction(bytes32 indexed id, bool restricted);
    event ShareRestriction(address indexed share, bool restricted);
    event GlobalRestriction(bool restricted);

    /**
        @notice Issuing entity constructor
        @param _owners Array of addresses to associate with owner
        @param _threshold multisig threshold for owning authority
     */
    constructor(
        address[] _owners,
        uint32 _threshold
    )
        MultiSig(_owners, _threshold)
        public
    {
        /* First verifier is empty so Account.regKey == 0 means it is unset. */
        verifiers.push(VerifierContract(IIDVerifier(0), false));
        idMap[address(this)].id = ownerID;
    }

    /**
        @notice Check if an address belongs to a registered member
        @dev Retrurns false for custodian or org addresses
        @param _addr address to check
        @return bytes32 member ID
     */
    function isRegisteredMember(address _addr) external view returns (bool) {
        bytes32 _id = _getID(_addr);
        return accounts[_id].rating > 0;
    }

    /**
        @notice Check if a share is associated to this contract and unrestricted
        @param _share address to check
        @return boolean
     */
    function isActiveOrgShare(address _share) external view returns (bool) {
        return shares[_share].set && !shares[_share].restricted;
    }

    /**
        @notice External view to fetch an member ID from an address
        @param _addr address to check
        @return bytes32 member ID
     */
    function getID(address _addr) external view returns (bytes32 _id) {
        _id = _getID(_addr);
        if (_id == ownerID) {
            return idMap[_addr].id;
        }
        return _id;
    }

    /**
        @notice Get address of the verifier an member is associated with
        @param _id Member ID
        @return verifier address
     */
    function getMemberVerifier(bytes32 _id) external view returns (address) {
        return verifiers[accounts[_id].regKey].addr;
    }

    /**
        @notice Fetch total member counts and limits
        @return counts, limits
     */
    function getMemberCounts()
    external
    view
    returns (
        uint32[8] _counts,
        uint32[8] _limits
    )
    {
        return (counts, limits);
    }

    /**
        @notice Fetch minrating, member counts and limits of a country
        @dev counts[0] and levels[0] == the sum of counts[1:] and limits[1:]
        @param _country Country to query
        @return uint32 minRating, uint32 arrays of counts, limits
     */
    function getCountry(
        uint16 _country
    )
        external
        view
        returns (uint32 _minRating, uint32[8] _count, uint32[8] _limit)
    {
        return (
            countries[_country].minRating,
            countries[_country].counts,
            countries[_country].limits
        );
    }

    /**
        @notice Fetch document hash
        @param _documentID Document ID to fetch
        @return document hash
     */
    function getDocumentHash(string _documentID) external view returns (bytes32) {
        return documentHashes[_documentID];
    }

    /**
        @notice Set document hash
        @param _documentID Document ID being hashed
        @param _hash Hash of the document
        @return bool success
     */
    function setDocumentHash(
        string _documentID,
        bytes32 _hash
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        require(documentHashes[_documentID] == 0);
        documentHashes[_documentID] = _hash;
        emit NewDocumentHash(_documentID, _hash);
        return true;
    }

    /**
        @notice Add a new OrgShare contract
        @dev Requires permission from governance module
        @param _share Share contract address
        @return bool success
     */
    function addOrgShare(address _share) external returns (bool) {
        if (!_checkMultiSig()) return false;
        IOrgShareBase share = IOrgShareBase(_share);
        require(!shares[_share].set); // dev: already set
        require(share.ownerID() == ownerID); // dev: wrong owner
        require(share.circulatingSupply() == 0);
        if (address(governance) != 0x00) {
            require(governance.addOrgShare(_share), "Action has not been approved");
        }
        shares[_share].set = true;
        emit ShareAdded(_share);
        return true;
    }

    /**
        @notice Add a new authority
        @param _addr Array of addressses to register as authority
        @param _signatures Array of bytes4 sigs this authority may call
        @param _approvedUntil Epoch time that authority is approved until
        @param _threshold Minimum number of calls to a method for multisig
        @return bool success
     */
    function addAuthority(
        address[] _addr,
        bytes4[] _signatures,
        uint32 _approvedUntil,
        uint32 _threshold
    )
        public
        returns (bool)
    {
        require(!accounts[keccak256(abi.encodePacked(_addr))].set); // dev: known ID
        super.addAuthority(_addr, _signatures, _approvedUntil, _threshold);
        return true;
    }

    /**
        @notice Add a custodian
        @dev
            Custodians are entities such as broker or exchanges that are approved
            to hold shares for one or more beneficial owners.
            https://sft-protocol.readthedocs.io/en/latest/custodian.html
        @param _custodian address of custodian contract
        @return bool success
     */
    function addCustodian(address _custodian) external returns (bool) {
        if (!_checkMultiSig()) return false;
        bytes32 _id = ICustodian(_custodian).ownerID();
        require(_id != 0); // dev: zero ID
        require(idMap[_custodian].id == 0); // dev: known address
        require(!accounts[_id].set); // dev: known ID
        require(authorityData[_id].addressCount == 0); // dev: authority ID
        idMap[_custodian].id = _id;
        accounts[_id].custodian = _custodian;
        accounts[_id].set = true;
        emit CustodianAdded(_custodian);
        return true;
    }

    /**
        @notice Set the governance module
        @dev Setting the address to 0x00 is equivalent to disabling it
        @param _governance Governance module address
        @return bool success
     */
    function setGovernance(IGovernance _governance) external returns (bool) {
        if (!_checkMultiSig()) return false;
        if (address(_governance) != 0x00) {
            require (_governance.orgCode() == address(this)); // dev: wrong org
        }
        governance = _governance;
        emit GovernanceSet(_governance);
        return true;
    }

    /**
        @notice Attach or restrict a IIDVerifierBase contract
        @param _verifier address of verifier
        @param _restricted verifier permission
        @return bool success
     */
    function setVerifier(
        IIDVerifier _verifier,
        bool _restricted
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        emit VerifierSet(_verifier, _restricted);
        for (uint256 i = 1; i < verifiers.length; i++) {
            if (verifiers[i].addr == _verifier) {
                verifiers[i].restricted = _restricted;
                return true;
            }
        }
        if (!_restricted) {
            verifiers.push(VerifierContract(_verifier, _restricted));
            return true;
        }
        revert(); // dev: unknown verifier
    }

    /**
        @notice Set all information about a country
        @param _country Country to modify
        @param _permitted Is country approved
        @param _minRating minimum member rating
        @param _limits array of member limits
        @return bool success
     */
    function setCountry(
        uint16 _country,
        bool _permitted,
        uint8 _minRating,
        uint32[8] _limits
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        Country storage c = countries[_country];
        c.limits = _limits;
        c.minRating = _minRating;
        c.permitted = _permitted;
        emit CountryModified(_country, _permitted, _minRating, _limits);
        return true;
    }

    /**
        @notice Initialize many countries in a single call
        @dev
            This call is useful if you have a lot of countries to approve
            where there is no member limit specific to the member ratings
        @param _country Array of counties to add
        @param _minRating Array of minimum member ratings necessary for each country
        @param _limit Array of maximum mumber of members allowed from this country
        @return bool success
     */
    function setCountries(
        uint16[] _country,
        uint8[] _minRating,
        uint32[] _limit
    )
        external
        returns (bool)
    {
        require(_country.length == _minRating.length);
        require(_country.length == _limit.length);
        if (!_checkMultiSig()) return false;
        for (uint256 i; i < _country.length; i++) {
            require(_minRating[i] != 0);
            Country storage c = countries[_country[i]];
            c.permitted = true;
            c.minRating = _minRating[i];
            c.limits[0] = _limit[i];
            emit CountryModified(_country[i], true, _minRating[i], c.limits);
        }
        return true;
    }

    /**
        @notice Set member limits
        @dev
            _limits[0] is the total member limit, [1:] correspond to limits
            at each specific member rating. Setting a value of 0 means there
            is no limit.
        @param _limits Array of limits
        @return bool success
     */
    function setMemberLimits(uint32[8] _limits) external returns (bool) {
        if (!_checkMultiSig()) return false;
        limits = _limits;
        emit MemberLimitsSet(_limits);
        return true;
    }

    /**
        @notice Set restriction on an member or custodian ID
        @dev restrictions on sub-authorities are handled via MultiSig methods
        @param _id member ID
        @param _restricted permission bool
        @return bool success
     */
    function setEntityRestriction(
        bytes32 _id,
        bool _restricted
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        require(authorityData[_id].addressCount == 0); // dev: authority
        accounts[_id].restricted = _restricted;
        emit EntityRestriction(_id, _restricted);
        return true;
    }

    /**
        @notice Set restriction on all shares within an OrgShare contract
        @dev
            Only the org can transfer restricted shares. Useful in dealing
            with a security breach or a contract migration.
        @param _share Address of the share contract
        @param _restricted permission bool
        @return bool success
     */
    function setOrgShareRestriction(
        address _share,
        bool _restricted
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        require(shares[_share].set);
        shares[_share].restricted = _restricted;
        emit ShareRestriction(_share, _restricted);
        return true;
    }

    /**
        @notice Set restriction on all shares for this org
        @dev Only the org can transfer restricted shares.
        @param _restricted permission bool
        @return bool success
     */
    function setGlobalRestriction(bool _restricted) external returns (bool) {
        if (!_checkMultiSig()) return false;
        locked = _restricted;
        emit GlobalRestriction(_restricted);
        return true;
    }

    /**
        @notice Check if transfer is possible based on org level restrictions
        @dev function is not called directly - see OrgShare.checkTransfer
        @param _auth address of the caller attempting the transfer
        @param _from address of the sender
        @param _to address of the receiver
        @param _zero is the sender's balance zero after the transfer?
        @return bytes32 ID of caller
        @return bytes32[] IDs of sender and receiver
        @return uint8[] ratings of sender and receiver
        @return uint16[] countries of sender and receiver
     */
    function checkTransfer(
        address _auth,
        address _from,
        address _to,
        bool _zero
    )
        public
        returns (
            bytes32 _authID,
            bytes32[2] _id,
            uint8[2] _rating,
            uint16[2] _country
        )
    {
        _authID = _getID(_auth);
        _id[SENDER] = _getID(_from);
        _id[RECEIVER] = _getID(_to);

        if (_authID == ownerID && idMap[_auth].id != ownerID) {
            /* This enforces sub-authority permissioning around transfers */
            Authority storage a = authorityData[idMap[_auth].id];
            require(
                a.approvedUntil >= now &&
                a.signatures[bytes4(_authID == _id[SENDER] ? 0xa9059cbb : 0x23b872dd)],
                "Authority not permitted"
            );
        }

        address _addr = (_authID == _id[SENDER] ? _auth : _from);
        bool[2] memory _permitted;

        (_permitted, _rating, _country) = _getMembers(
            [_addr, _to],
            [accounts[idMap[_addr].id].regKey, accounts[_id[RECEIVER]].regKey]
        );
        if (accounts[_authID].custodian != 0) {
            require(accounts[_id[RECEIVER]].custodian == 0, "Custodian to Custodian");
        }

        /* must be allowed to underflow in case of org zero balance */
        uint32 _count = accounts[_id[SENDER]].count;
        if (_zero) _count -= 1;

        _checkTransfer(_authID, _id, _permitted, _rating, _country, _count);
        return (_authID, _id, _rating, _country);
    }

    /**
        @notice internal member ID fetch
        @param _addr Member address
        @return bytes32 member ID
     */
    function _getID(address _addr) internal returns (bytes32 _id) {
        _id = idMap[_addr].id;
        if (authorityData[_id].addressCount > 0) {
            require(!idMap[_addr].restricted, "Restricted Authority Address");
            return ownerID;
        }
        if (
            (
                accounts[_id].regKey > 0 &&
                !verifiers[accounts[_id].regKey].restricted
            ) || accounts[_id].custodian != 0
        ) {
            return _id;
        }
        if (_id == 0) {
            for (uint256 i = 1; i < verifiers.length; i++) {
                if (!verifiers[i].restricted) {
                    _id = verifiers[i].addr.getID(_addr);
                    /* prevent member / authority ID collisions */
                    if (_id != 0 && authorityData[_id].addressCount == 0) {
                        idMap[_addr].id = _id;
                        if (!accounts[_id].set) {
                            accounts[_id].set = true;
                            accounts[_id].regKey = uint8(i);
                        } else if (accounts[_id].regKey != i) {
                            continue;
                        }
                        accounts[_id].regKey = uint8(i);
                        return _id;
                    }
                }
            }
        } else {
            for (i = 1; i < verifiers.length; i++) {
                if (verifiers[i].restricted) continue;
                if (_id != verifiers[i].addr.getID(_addr)) continue;
                accounts[_id].regKey = uint8(i);
                return _id;
            }
            revert("Verifier restricted");
        }
        revert("Address not registered");
    }

    /**
        @notice Internal function for fetching member data from verifiers
        @dev Either _addr or _id may be given as an empty array
        @param _addr array of member addresses
        @param _key array of verifier indexes
        @return permissions, ratings, and countries of members
     */
    function _getMembers(
        address[2] _addr,
        uint8[2] _key
    )
        internal
        view
        returns (
            bool[2] _permitted,
            uint8[2] _rating,
            uint16[2] _country
        )
    {
        /* If both members are in the same verifier, call getMembers */
        IIDVerifier r = verifiers[_key[SENDER]].addr;
        if (_key[SENDER] > 0 && _key[SENDER] == _key[RECEIVER]) {
            (
                ,
                _permitted,
                _rating,
                _country
            ) = r.getMembers(_addr[SENDER], _addr[RECEIVER]);
            return (_permitted, _rating, _country);
        }
        /* Otherwise, call getMember at each verifier */
        if (_key[SENDER] != 0) {
            (
                ,
                _permitted[SENDER],
                _rating[SENDER],
                _country[SENDER]
            ) = r.getMember(_addr[SENDER]);
        } else {
            /* If key == 0 the address belongs to the org or a custodian. */
            _permitted[SENDER] = true;
        }
        if (_key[RECEIVER] != 0) {
            r = verifiers[_key[RECEIVER]].addr;
            (
                ,
                _permitted[RECEIVER],
                _rating[RECEIVER],
                _country[RECEIVER]
            ) = r.getMember(_addr[RECEIVER]);
        } else {
            _permitted[RECEIVER] = true;
        }
        return (_permitted, _rating, _country);
    }

    /**
        @notice internal check if transfer is permitted
        @param _authID id hash of caller
        @param _id addresses of sender and receiver
        @param _permitted array of permission bools from verifier
        @param _rating array of member ratings
        @param _country array of member countries
        @param _shareCount sender accounts.count value after transfer
     */
    function _checkTransfer(
        bytes32 _authID,
        bytes32[2] _id,
        bool[2] _permitted,
        uint8[2] _rating,
        uint16[2] _country,
        uint32 _shareCount
    )
        internal
        view
    {
        require(shares[msg.sender].set);
        /* If org is not the authority, check the sender is not restricted */
        if (_authID != ownerID) {
            require(!locked, "Transfers locked: Org");
            require(!shares[msg.sender].restricted, "Transfers locked: Share");
            require(!accounts[_id[SENDER]].restricted, "Sender restricted: Org");
            require(_permitted[SENDER], "Sender restricted: Verifier");
            require(!accounts[_authID].restricted, "Authority restricted");
        }
        /* Always check the receiver is not restricted. */
        require(!accounts[_id[RECEIVER]].restricted, "Receiver restricted: Org");
        require(_permitted[RECEIVER], "Receiver restricted: Verifier");
        if (_id[SENDER] != _id[RECEIVER]) {
            /*
                A rating of 0 implies the receiver is the org or a
                custodian, no further checks are needed.
            */
            if (_rating[RECEIVER] != 0) {
                Country storage c = countries[_country[RECEIVER]];
                require(c.permitted, "Receiver blocked: Country");
                require(_rating[RECEIVER] >= c.minRating, "Receiver blocked: Rating");
                /*
                    If the receiving member currently has 0 balance and no
                    custodians, make sure a slot is available for allocation.
                */
                if (accounts[_id[RECEIVER]].count == 0) {
                    /* create a bool to prevent repeated comparisons */
                    bool _check = (_rating[SENDER] == 0 || _shareCount > 0);
                    /*
                        If the sender is an member and still retains a balance,
                        a new slot must be available.
                    */
                    if (_check) {
                        require(
                            limits[0] == 0 ||
                            counts[0] < limits[0],
                            "Total Member Limit"
                        );
                    }
                    /*
                        If the members are from different countries, make sure
                        a slot is available in the overall country limit.
                    */
                    if (_check || _country[SENDER] != _country[RECEIVER]) {
                        require(
                            c.limits[0] == 0 ||
                            c.counts[0] < c.limits[0],
                            "Country Member Limit"
                        );
                    }
                    if (!_check) {
                        _check = _rating[SENDER] != _rating[RECEIVER];
                    }
                    /*
                        If the members are of different ratings, make sure a
                        slot is available in the receiver's rating in the overall
                        count.
                    */
                    if (_check) {
                        require(
                            limits[_rating[RECEIVER]] == 0 ||
                            counts[_rating[RECEIVER]] < limits[_rating[RECEIVER]],
                            "Total Member Limit: Rating"
                        );
                    }
                    /*
                        If the members don't match in country or rating, make
                        sure a slot is available in both the specific country
                        and rating for the receiver.
                    */
                    if (_check || _country[SENDER] != _country[RECEIVER]) {
                        require(
                            c.limits[_rating[RECEIVER]] == 0 ||
                            c.counts[_rating[RECEIVER]] < c.limits[_rating[RECEIVER]],
                            "Country Member Limit: Rating"
                        );
                    }
                }
            }
        }
    }

    /**
        @notice Transfer shares through the issuing entity level
        @dev only callable through an OrgShare contract
        @param _auth Caller address
        @param _from Sender address
        @param _to Receiver address
        @param _zero Array of zero balance booleans
            Is sender balance now zero?
            Was receiver balance zero?
            Is sender custodial balance now zero?
            Was receiver custodial balance zero?
        @return authority ID, IDs/ratings/countries for sender/receiver
     */
    function transferShares(
        address _auth,
        address _from,
        address _to,
        bool[4] _zero
    )
        external
        returns (
            bytes32 _authID,
            bytes32[2] _id,
            uint8[2] _rating,
            uint16[2] _country
        )
    {
        (_authID, _id, _rating, _country) = checkTransfer(_auth, _from, _to, _zero[0]);

        /* If no transfer of ownership, return true immediately */
        if (_id[SENDER] == _id[RECEIVER]) return;

        /* if sender is a normal member */
        if (_rating[SENDER] != 0) {
            _setRating(_id[SENDER], _rating[SENDER], _country[SENDER]);
            if (_zero[0]) {
                Account storage a = accounts[_id[SENDER]];
                a.count = a.count.sub(1);
                /* If member account balance is now 0, lower member counts */
                if (a.count == 0) {
                    _decrementCount(_rating[SENDER], _country[SENDER]);
                }
            }
        /* if receiver is not the org, and sender is a custodian */
        } else if (_id[SENDER] != ownerID && _id[RECEIVER] != ownerID) {
            if (_zero[2]) {
                a = accounts[_id[RECEIVER]];
                a.count = a.count.sub(1);
                if (a.count == 0) {
                    _decrementCount(_rating[RECEIVER], _country[RECEIVER]);
                }
            }
        }
        /* if receiver is a normal member */
        if (_rating[RECEIVER] != 0) {
            _setRating(_id[RECEIVER], _rating[RECEIVER], _country[RECEIVER]);
            if (_zero[1]) {
                a = accounts[_id[RECEIVER]];
                a.count = a.count.add(1);
                /* If member account balance was 0, increase member counts */
                if (a.count == 1) {
                    _incrementCount(_rating[RECEIVER], _country[RECEIVER]);
                }
            }
        /* if sender is not the org, and receiver is a custodian */
        } else if (_id[SENDER] != ownerID && _id[RECEIVER] != ownerID) {
            if (_zero[3]) {
                a = accounts[_id[SENDER]];
                a.count = a.count.add(1);
                if (a.count == 1) {
                    _incrementCount(_rating[SENDER], _country[SENDER]);
                }
            }
        }
        return (_authID, _id, _rating, _country);
    }

    /**
        @notice Affect a direct balance change (burn/mint) at the issuing entity level
        @dev This can only be called by a share contract
        @param _owner Share owner
        @param _old Old balance
        @param _new New balance
        @return id, rating, and country of the affected member
     */
    function modifyShareTotalSupply(
        address _owner,
        uint256 _old,
        uint256 _new
    )
        external
        returns (
            bytes32 _id,
            uint8 _rating,
            uint16 _country
        )
    {
        require(!locked); // dev: global lock
        require(shares[msg.sender].set);
        require(!shares[msg.sender].restricted); // dev: share locked
        if (_owner == address(this)) {
            _id = ownerID;
        } else {
            require(accounts[idMap[_owner].id].custodian == 0); // dev: custodian
            uint8 _key = accounts[idMap[_owner].id].regKey;
            (_id, , _rating, _country) = verifiers[_key].addr.getMember(_owner);
        }
        Account storage a = accounts[_id];
        if (_id != ownerID) {
            _setRating(_id, _rating, _country);
            if (_old == 0) {
                a.count = a.count.add(1);
                if (a.count == 1) {
                    _incrementCount(_rating, _country);
                }
            } else if (_new == 0) {
                a.count = a.count.sub(1);
                if (a.count == 0) {
                    _decrementCount(_rating, _country);
                }
            }
        }
        return (_id, _rating, _country);
    }

    /**
        @notice Check and modify an member's rating in contract storage
        @param _id Member ID
        @param _rating Member rating
        @param _country Member country
     */
    function _setRating(bytes32 _id, uint8 _rating, uint16 _country) internal {
        Account storage a = accounts[_id];
        if (_rating == a.rating) return;
        /* if local rating is not 0, rating has changed */
        if (a.rating > 0) {
            uint32[8] storage c = countries[_country].counts;
            c[_rating] = c[_rating].sub(1);
            c[a.rating] = c[a.rating].add(1);
        }
        a.rating = _rating;
    }

    /**
        @notice Increment member count
        @param _r Member rating
        @param _c Member country
        @return bool success
     */
    function _incrementCount(uint8 _r, uint16 _c) internal {
        counts[0] = counts[0].add(1);
        counts[_r] = counts[_r].add(1);
        countries[_c].counts[0] = countries[_c].counts[0].add(1);
        countries[_c].counts[_r] = countries[_c].counts[_r].add(1);
    }

    /**
        @notice Decrement member count
        @param _r Member rating
        @param _c Member country
        @return bool success
     */
    function _decrementCount(uint8 _r, uint16 _c) internal {
        counts[0] = counts[0].sub(1);
        counts[_r] = counts[_r].sub(1);
        countries[_c].counts[0] = countries[_c].counts[0].sub(1);
        countries[_c].counts[_r] = countries[_c].counts[_r].sub(1);
    }

    /**
        @notice Modify authorized supply
        @dev Called by a share contract, requires permission from governance module
        @param _value New authorized supply value
        @return bool
     */
    function modifyAuthorizedSupply(uint256 _value) external returns (bool) {
        require(shares[msg.sender].set);
        require(!shares[msg.sender].restricted);
        if (address(governance) != 0x00) {
            require(
                governance.modifyAuthorizedSupply(msg.sender, _value),
                "Action has not been approved"
            );
        }
        return true;
    }

    /**
        @notice Attach a module to OrgCode or OrgShares
        @dev
            Modules have a lot of permission and flexibility in what they
            can do. Only attach a module that has been properly auditted and
            where you understand exactly what it is doing.
            https://sft-protocol.readthedocs.io/en/latest/modules.html
        @param _target Address of the contract where the module is attached
        @param _module Address of the module contract
        @return bool success
     */
    function attachModule(
        address _target,
        IBaseModule _module
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        address _owner = _module.getOwner();
        require(shares[_target].set); // dev: unknown target
        require (_owner == _target || _owner == address(this)); // dev: wrong owner
        require(IOrgShareBase(_target).attachModule(_module));
        return true;
    }

    /**
        @notice Detach a module from OrgCode or OrgShare
        @dev This function may also be called by the module itself.
        @param _target Address of the contract where the module is attached
        @param _module Address of the module contract
        @return bool success
     */
    function detachModule(
        address _target,
        address _module
    )
        external
        returns (bool)
    {
        if (!_checkMultiSig()) return false;
        require(shares[_target].set); // dev: unknown target
        require(IOrgShareBase(_target).detachModule(_module));
        return true;
    }

}
